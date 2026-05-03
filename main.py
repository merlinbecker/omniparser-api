from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from pydantic import BaseModel
from typing import Optional
import base64
import io
import os
import secrets

from PIL import Image
import torch
from ultralytics import YOLO
from transformers import AutoModelForCausalLM, AutoProcessor

from utils import check_ocr_box, get_som_labeled_img

os.environ.setdefault("TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD", "1")

try:
    yolo_model = YOLO("weights/icon_detect/best.pt").to("cuda")
except Exception:
    yolo_model = YOLO("weights/icon_detect/best.pt")

ALLOW_ONLINE_DOWNLOAD = os.getenv("OMNIPARSER_ALLOW_ONLINE_DOWNLOAD") == "1"
LOCAL_FILES_ONLY = not ALLOW_ONLINE_DOWNLOAD

processor = AutoProcessor.from_pretrained(
    "microsoft/Florence-2-base",
    trust_remote_code=True,
    local_files_only=LOCAL_FILES_ONLY,
)

florence_dtype = torch.float16 if torch.cuda.is_available() else torch.float32
model = AutoModelForCausalLM.from_pretrained(
    "weights/icon_caption_florence",
    torch_dtype=florence_dtype,
    attn_implementation="eager",
    trust_remote_code=True,
    local_files_only=LOCAL_FILES_ONLY,
)
if torch.cuda.is_available():
    model = model.to("cuda")

model.config.use_cache = False
if getattr(model, "generation_config", None) is not None:
    model.generation_config.use_cache = False

caption_model_processor = {"processor": processor, "model": model}
print("finish loading model!!!")

app = FastAPI()


@app.get("/")
async def root():
    return {"status": "ok"}


@app.get("/health")
async def health():
    return {"status": "ok"}


API_KEY_ENV_NAMES = ("OMNIPARSER-API-KEY", "OMNIPARSER_API_KEY")


def get_required_api_key() -> Optional[str]:
    return next(
        (os.getenv(env_name) for env_name in API_KEY_ENV_NAMES if os.getenv(env_name)),
        None,
    )


class ProcessResponse(BaseModel):
    image: str
    parsed_content_list: str
    label_coordinates: str


def process(
    image_input: Image.Image, box_threshold: float, iou_threshold: float
) -> ProcessResponse:
    image_save_path = "imgs/saved_image_demo.png"
    image_input.save(image_save_path)
    image = Image.open(image_save_path)
    box_overlay_ratio = image.size[0] / 3200
    draw_bbox_config = {
        "text_scale": 0.8 * box_overlay_ratio,
        "text_thickness": max(int(2 * box_overlay_ratio), 1),
        "text_padding": max(int(3 * box_overlay_ratio), 1),
        "thickness": max(int(3 * box_overlay_ratio), 1),
    }

    ocr_bbox_rslt, is_goal_filtered = check_ocr_box(
        image_save_path,
        display_img=False,
        output_bb_format="xyxy",
        goal_filtering=None,
        easyocr_args={"paragraph": False, "text_threshold": 0.9},
        use_paddleocr=False,
    )
    text, ocr_bbox = ocr_bbox_rslt
    dino_labled_img, label_coordinates, parsed_content_list = get_som_labeled_img(
        image_save_path,
        yolo_model,
        BOX_TRESHOLD=box_threshold,
        output_coord_in_ratio=True,
        ocr_bbox=ocr_bbox,
        draw_bbox_config=draw_bbox_config,
        caption_model_processor=caption_model_processor,
        ocr_text=text,
        iou_threshold=iou_threshold,
    )
    image = Image.open(io.BytesIO(base64.b64decode(dino_labled_img)))
    print("finish processing")
    parsed_content_list_str = "\n".join(parsed_content_list)

    buffered = io.BytesIO()
    image.save(buffered, format="PNG")
    img_str = base64.b64encode(buffered.getvalue()).decode("utf-8")

    return ProcessResponse(
        image=img_str,
        parsed_content_list=str(parsed_content_list_str),
        label_coordinates=str(label_coordinates),
    )


@app.post("/process_image", response_model=ProcessResponse)
async def process_image(
    image_file: UploadFile = File(...),
    box_threshold: float = 0.05,
    iou_threshold: float = 0.1,
    x_api_key: Optional[str] = Header(default=None, alias="x-api-key"),
):
    required_api_key = get_required_api_key()
    if not required_api_key:
        raise HTTPException(
            status_code=503,
            detail="Server auth is not configured. Set OMNIPARSER_API_KEY or OMNIPARSER-API-KEY.",
        )

    if not x_api_key or not secrets.compare_digest(x_api_key, required_api_key):
        raise HTTPException(status_code=401, detail="Invalid or missing API key")

    try:
        contents = await image_file.read()
        image_input = Image.open(io.BytesIO(contents)).convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid image file") from exc

    return process(image_input, box_threshold, iou_threshold)
