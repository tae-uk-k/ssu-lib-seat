"""Windows 알림(토스트)에 붙는 아이콘 `assets/icon/toast_icon.png` 를 만든다.

원본 `assets/icon/icon.png` 는 흰 배경이라 알림에서 색이 반전돼 보였다. 흰 배경을 투명하게 바꾼 256px 이미지를 만든다.
다시 만들려면: python tools/make_toast_icon.py   (Pillow 필요)
"""
import os

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SRC = os.path.join(ROOT, 'assets', 'icon', 'icon.png')
DST = os.path.join(ROOT, 'assets', 'icon', 'toast_icon.png')

im = Image.open(SRC).convert('RGB').resize((256, 256), Image.LANCZOS)
px = im.load()
out = Image.new('RGBA', im.size)
op = out.load()
for y in range(im.height):
    for x in range(im.width):
        r, g, b = px[x, y]
        lightest = min(r, g, b)  # 흰색에 가까울수록 크다
        # 200 이하(색이 있는 부분)는 불투명, 250 이상(흰 배경)은 투명, 그 사이(가장자리)는 부드럽게.
        a = 255 if lightest <= 200 else max(0, int((250 - lightest) * 255 / 50))
        op[x, y] = (r, g, b, a)
out.save(DST, optimize=True)
print('저장:', DST, os.path.getsize(DST), '바이트')
