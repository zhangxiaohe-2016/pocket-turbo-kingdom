#!/usr/bin/env python3
# 生成「口袋赛车王国」App 图标（纯 Python 标准库，不依赖 PIL / 网络）。
#
# 用法：python3 make_icon.py <输出目录>          # 通常是 build/<App>.app
#
# 主题：卡通赛车 + 速度感 —— 深青渐变底、青色速度线、亮黄卡丁车侧影。
# 全部用几何图元（圆 / 圆角矩形 / 三角形）+ 超采样抗锯齿绘制，
# 和 ~/LLMChat-iOS12/make_icon.py 同一套手写 PNG 编码（sRGB RGBA，无外部依赖）。
import sys, struct, zlib
from pathlib import Path

# ---------------- 配色 ----------------
BG_TOP = (0x0E, 0x3B, 0x44)     # 深青
BG_BOT = (0x03, 0x16, 0x1B)     # 近黑青
GLOW = (0x18, 0x5A, 0x62)       # 车体后面的柔光
CYAN = (0x27, 0x9C, 0xA8)       # 速度线
CYAN_HI = (0x45, 0xD8, 0xCE)    # 高亮速度线
YELLOW = (0xFF, 0xD1, 0x1E)     # 车身亮黄（主色）
YELLOW_DK = (0xE0, 0x99, 0x00)  # 车身暗黄（结构件）
TIRE = (0x14, 0x17, 0x1B)       # 轮胎
RIM = (0xE8, 0xEF, 0xF2)        # 轮辋
DARK = (0x0B, 0x27, 0x2C)       # 头盔面罩
ORANGE = (0xFF, 0x7A, 0x1F)     # 尾焰
FLAME = (0xFF, 0xF0, 0x9A)      # 尾焰内芯


# ---------------- 几何 ----------------
def _in_rrect(x, y, cx, cy, hw, hh, r):
    """点是否落在中心 (cx,cy)、半宽半高 (hw,hh)、圆角 r 的圆角矩形内。"""
    dx = abs(x - cx)
    dy = abs(y - cy)
    if dx > hw or dy > hh:
        return False
    if dx <= hw - r and dy <= hh - r:
        return True                      # 内矩形
    if dx > hw - r and dy > hh - r:      # 四个圆角
        qx = dx - (hw - r)
        qy = dy - (hh - r)
        return qx * qx + qy * qy <= r * r
    return True                          # 边条带


def _in_circle(x, y, cx, cy, r):
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= r * r


def _in_tri(x, y, a, b, c):
    def sign(p1, p2, p3):
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])
    d1 = sign((x, y), a, b)
    d2 = sign((x, y), b, c)
    d3 = sign((x, y), c, a)
    neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (neg and pos)


def _mix(a, b, k):
    return (a[0] + (b[0] - a[0]) * k,
            a[1] + (b[1] - a[1]) * k,
            a[2] + (b[2] - a[2]) * k)


# ---------------- 图形（y 轴向下，坐标归一化到 0..1）----------------
def _sample(x, y):
    # 1) 深青渐变底
    col = _mix(BG_TOP, BG_BOT, y)
    # 2) 车体后方柔光
    dx, dy = x - 0.52, y - 0.60
    d2 = dx * dx + dy * dy
    if d2 < 0.62 * 0.62:
        col = _mix(col, GLOW, (1.0 - (d2 ** 0.5) / 0.62) * 0.22)

    # 3) 速度线（背景层，避开车身所在的 y 0.33~0.86）
    if _in_rrect(x, y, 0.050, 0.195, 0.155, 0.020, 0.020) \
       or _in_rrect(x, y, 0.030, 0.115, 0.115, 0.016, 0.016) \
       or _in_rrect(x, y, 0.070, 0.885, 0.135, 0.018, 0.018) \
       or _in_rrect(x, y, 0.100, 0.945, 0.195, 0.016, 0.016):
        col = CYAN
    if _in_rrect(x, y, 0.170, 0.115, 0.075, 0.014, 0.014):
        col = CYAN_HI

    # 4) 尾焰（画在最底层，根部压在车身下面 → 像是从车尾喷出来）
    if _in_tri(x, y, (0.205, 0.548), (0.020, 0.594), (0.205, 0.640)):
        col = ORANGE
        if _in_tri(x, y, (0.205, 0.568), (0.078, 0.594), (0.205, 0.620)):
            col = FLAME

    # 5) 轮胎（先画轮子，车身盖住上半部分 → 轮拱效果）
    rear = _in_circle(x, y, 0.275, 0.735, 0.118)
    front = _in_circle(x, y, 0.745, 0.735, 0.118)
    if rear or front:
        col = TIRE
        cx = 0.275 if rear else 0.745
        if _in_circle(x, y, cx, 0.735, 0.050):
            col = RIM
            if _in_circle(x, y, cx, 0.735, 0.019):
                col = YELLOW

    # 6) 尾翼 + 支柱
    if _in_rrect(x, y, 0.210, 0.372, 0.090, 0.030, 0.018):
        col = YELLOW
    elif _in_rrect(x, y, 0.210, 0.440, 0.025, 0.075, 0.012):
        col = YELLOW_DK
    # 7) 引擎罩
    elif _in_rrect(x, y, 0.245, 0.545, 0.055, 0.060, 0.030):
        col = YELLOW_DK
    # 8) 车头锥
    elif _in_tri(x, y, (0.715, 0.507), (0.895, 0.585), (0.715, 0.663)):
        col = YELLOW
    # 9) 主车体 + 侧身拉花
    elif _in_rrect(x, y, 0.460, 0.585, 0.285, 0.078, 0.048):
        col = YELLOW
        if _in_rrect(x, y, 0.600, 0.620, 0.200, 0.018, 0.018):
            col = YELLOW_DK
    # 10) 头盔 + 面罩
    elif _in_circle(x, y, 0.445, 0.435, 0.090):
        col = YELLOW
        if _in_rrect(x, y, 0.487, 0.428, 0.042, 0.028, 0.026):
            col = DARK

    return col


# ---------------- PNG 编码 ----------------
def _write_png(path, w, h, pixels):
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + \
               struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for (r, g, b, a) in row:
            raw += bytes((r, g, b, a))
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    Path(path).write_bytes(png)


def render(size):
    """超采样求平均 → 抗锯齿。小图多用几倍采样，大图降低以控制耗时。"""
    if size < 64:
        ss = 6
    elif size < 256:
        ss = 3
    else:
        ss = 2
    n = ss * ss
    pixels = []
    for py in range(size):
        row = []
        for px in range(size):
            r = g = b = 0.0
            for sy in range(ss):
                y = (py * ss + sy + 0.5) / (size * ss)
                for sx in range(ss):
                    x = (px * ss + sx + 0.5) / (size * ss)
                    cr, cg, cb = _sample(x, y)
                    r += cr
                    g += cg
                    b += cb
            row.append((int(r / n), int(g / n), int(b / n), 255))
        pixels.append(row)
    return pixels


ICONS = {
    'Icon-20.png': 20, 'Icon-20@2x.png': 40, 'Icon-20@3x.png': 60,
    'Icon-29.png': 29, 'Icon-29@2x.png': 58, 'Icon-29@3x.png': 87,
    'Icon-40.png': 40, 'Icon-40@2x.png': 80, 'Icon-40@3x.png': 120,
    'Icon-60@2x.png': 120, 'Icon-60@3x.png': 180,
    'Icon-76.png': 76, 'Icon-76@2x.png': 152,
    'Icon-83.5@2x.png': 167,
    'Icon-1024.png': 1024,
}


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, size in ICONS.items():
        _write_png(out / name, size, size, render(size))
        print(f'  {name} ({size}px)')
    print('==> 图标生成完毕（深青底 + 亮黄卡丁车）')


if __name__ == '__main__':
    main()
