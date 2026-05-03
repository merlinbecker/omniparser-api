FROM registry.hf.space/microsoft-omniparser:latest

USER root

RUN chmod 1777 /tmp \
    && apt update -q && apt install -y ca-certificates wget libgl1 \
    && wget -qO /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i /tmp/cuda-keyring.deb && apt update -q \
    && apt install -y --no-install-recommends libcudnn8 libcublas-12-2

RUN pip install fastapi[all]

# Pre-download EasyOCR assets into the image filesystem.
RUN python - <<'PY'
import easyocr

easyocr.Reader(['en'])
print('Pre-downloaded EasyOCR assets.')
PY

# Patch the upstream utils.py to avoid runtime PaddleOCR initialization.
RUN python - <<'PY'
from pathlib import Path

path = Path('/home/user/app/utils.py')
text = path.read_text()
old = """paddle_ocr = PaddleOCR(
    lang='en',  # other lang also available
    use_angle_cls=False,
    use_gpu=False,  # using cuda will conflict with pytorch in the same process
    show_log=False,
    max_batch_size=1024,
    use_dilation=True,  # improves accuracy
    det_db_score_mode='slow',  # improves accuracy
    rec_batch_num=1024)
"""
new = """paddle_ocr = None
"""

if old not in text:
    raise RuntimeError('Expected PaddleOCR block not found in /home/user/app/utils.py')

path.write_text(text.replace(old, new))
print('Patched /home/user/app/utils.py for PaddleOCR compatibility.')
PY

RUN python - <<'PY'
from pathlib import Path

path = Path('/home/user/app/utils.py')
text = path.read_text()
old = """        if 'florence' in model.config.name_or_path:
            generated_ids = model.generate(input_ids=inputs[\"input_ids\"],pixel_values=inputs[\"pixel_values\"],max_new_tokens=1024,num_beams=3, do_sample=False)
"""
new = """        if 'florence' in model.config.name_or_path:
            generated_ids = model.generate(
                input_ids=inputs[\"input_ids\"],
                pixel_values=inputs[\"pixel_values\"],
                max_new_tokens=1024,
                num_beams=1,
                do_sample=False,
                use_cache=False,
            )
"""

if old not in text:
    raise RuntimeError('Expected Florence generate block not found in /home/user/app/utils.py')

path.write_text(text.replace(old, new))
print('Patched /home/user/app/utils.py for Florence CPU generation.')
PY

ARG BUILD_TIMESTAMP=0
RUN echo "Build timestamp: ${BUILD_TIMESTAMP}"

COPY main.py main.py

# Preload YOLO and Florence artifacts during build, so cold starts remain offline.
RUN env 'OMNIPARSER-API-KEY=build-time-key' 'OMNIPARSER_ALLOW_ONLINE_DOWNLOAD=1' python - <<'PY'
import main
print('Preloaded all model artifacts via main import.')
PY

CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-7860}"]
