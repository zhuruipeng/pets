#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成软著登记用的「程序鉴别材料」PDF（源代码前后各 30 页）。

中国版权保护中心的要求：程序量超过 60 页的，交**前 30 页 + 后 30 页**，
每页 50 行，页眉标注软件全称 + 版本号 + 页码。

    python tool/make_copyright_pdf.py

产物落在 docs/store/ 下。软件全称 / 版本号在下面的常量里改，
不用动生成逻辑。
"""
import os
import sys

from fpdf import FPDF

# ---------------------------------------------------------------- 可调参数
SOFT_NAME = "我的宠物App软件"
SOFT_VER = "V0.1.5"
LINES_PER_PAGE = 50
FIRST_PAGES = 30   # 前 30 页
LAST_PAGES = 30    # 后 30 页
HERE = os.path.dirname(os.path.abspath(__file__))
# tool/ 在 app/ 下，docs/ 在仓库根（app 的上一级）。
APP = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(
    REPO, "docs", "store", f"软著-程序鉴别材料-源代码-{SOFT_VER}.pdf"
)
FONT = r"C:\Windows\Fonts\simhei.ttf"

# 源码的收录顺序：入口 → 核心 → 数据 → 领域 → 服务 → 界面。
# 顺序只影响「前 30 页」看到什么，把它排成读起来最顺的样子。
DIRS = [
    ("lib/main.dart",),
    ("lib/core",),
    ("lib/data",),
    ("lib/domain",),
    ("lib/services",),
    ("lib/ui",),
    ("android/app/src/main/kotlin",),
]


def collect_files():
    files = []
    for entry in DIRS:
        root = os.path.join(APP, entry[0])
        if os.path.isfile(root):
            files.append(os.path.normpath(root))
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            for fn in sorted(filenames):
                if fn.endswith((".dart", ".kt")):
                    files.append(os.path.normpath(os.path.join(dirpath, fn)))
    return files


def read_lines(files):
    lines = []
    total = 0
    for f in files:
        rel = os.path.relpath(f, APP).replace("\\", "/")
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                body = fh.read().splitlines()
        except OSError as e:
            print(f"跳过 {rel}: {e}")
            continue
        lines.append(f"// ==================== {rel} ====================")
        lines.extend(body)
        lines.append("")
        total += len(body)
    return lines, total


def main():
    files = collect_files()
    lines, real = read_lines(files)
    cap = (FIRST_PAGES + LAST_PAGES) * LINES_PER_PAGE

    if len(lines) > cap:
        # 省略标记自己也占一行，扣掉它才正好 60 页。
        half = (cap - 1) // 2
        omit = len(lines) - cap
        chosen = (
            lines[:half]
            + [f"// ……（中间省略 {omit} 行，程序总量 {real} 行）……"]
            + lines[-half:]
        )
    else:
        chosen = lines

    pdf = FPDF(format="A4")
    pdf.set_margins(20, 18, 20)
    pdf.set_auto_page_break(False)
    pdf.add_font("hei", "", FONT)

    header = f"{SOFT_NAME} {SOFT_VER}"
    avail_w = pdf.w - pdf.l_margin - pdf.r_margin
    body_top = pdf.t_margin + 10
    body_bottom = pdf.h - pdf.b_margin
    line_h = (body_bottom - body_top) / LINES_PER_PAGE

    def new_page():
        pdf.add_page()
        pdf.set_font("hei", size=10)
        pdf.set_text_color(60, 60, 60)
        pdf.cell(
            avail_w, 6,
            f"{header}    第 {pdf.page_no()} 页 / 共 {TOTAL_PAGES} 页",
            align="C", new_x="LMARGIN", new_y="NEXT",
        )
        pdf.set_text_color(0, 0, 0)
        pdf.set_font("hei", size=9)
        pdf.set_y(body_top)

    total_pages = -(-len(chosen) // LINES_PER_PAGE)  # ceil
    TOTAL_PAGES = total_pages

    for i, ln in enumerate(chosen):
        if i % LINES_PER_PAGE == 0:
            new_page()
        ln = ln.expandtabs(4).rstrip()
        # simhei 没有 emoji 等扩展区字形，直接去掉（fpdf 会整行缺字警告）。
        ln = "".join(ch for ch in ln if ord(ch) < 0x1F000)
        # 超宽就截断：鉴别材料看的是代码量与真实感，不是某一行的完整性。
        while ln and pdf.get_string_width(ln) > avail_w:
            ln = ln[:-1]
        pdf.cell(avail_w, line_h, ln, new_x="LMARGIN", new_y="NEXT")

    pdf.output(OUT)
    print(f"源码 {real} 行 → 收录 {len(chosen)} 行 → {TOTAL_PAGES} 页")
    print(f"输出: {OUT}")


if __name__ == "__main__":
    sys.exit(main())
