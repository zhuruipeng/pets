#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成软著登记用的「文档鉴别材料」——操作说明书 PDF。

中国版权保护中心要求：文档超 60 页交前 30 + 后 30 页；本手册 10 页左右，
整本提交。页眉带软件全称 + 版本号 + 页码，与程序鉴别材料同一套格式。

    python tool/make_copyright_manual.py

章节与截图在 SECTIONS 里改，图片取 docs/store/screenshots/。
"""
import os
import sys

from fpdf import FPDF
from PIL import Image

SOFT_NAME = "我的宠物App软件"
SOFT_VER = "V0.1.5"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
SHOTS = os.path.join(REPO, "docs", "store", "screenshots")
OUT = os.path.join(
    REPO, "docs", "store", f"软著-文档鉴别材料-操作说明书-{SOFT_VER}.pdf"
)
FONT = r"C:\Windows\Fonts\simhei.ttf"
IMG_W = 74  # 截图展示宽度 mm

# (标题, 正文段落列表, 截图文件名, 图注)
SECTIONS = [
    (
        "一、软件概述",
        [
            "「我的宠物App软件」（以下简称本软件）是一款面向宠物主人的宠物健康管理"
            "工具，提供宠物档案管理、健康记录、免疫提醒、费用追踪、文档原件留存与"
            "多设备数据同步等功能。",
            "本手册按功能模块介绍各主要功能的操作方法，供用户与审核人员参考。",
        ],
        None,
        "",
    ),
    (
        "二、启动与首页",
        [
            "启动软件后进入首页。首页自上而下依次为：问候语、当前宠物卡片（头像、"
            "昵称、年龄、当前体重与最近一条记录时间）、本周概览（本周记录条数与"
            "体重变化）、快捷记录入口、今日记录列表。",
            "点击右上角铃铛图标可查看今日待办；点击待办卡片可直接完成或稍后提醒。",
        ],
        "01-home-first-pet.jpg",
        "图 1  首页：宠物卡片、本周概览与快捷记录",
    ),
    (
        "三、今日记录",
        [
            "首页「今日记录」按时间倒序列出当天记录的全部条目（睡眠、就诊、体重、"
            "饮水、洗澡美容等），标题右侧显示当天总条数。当天没有记录时该区域自动"
            "隐藏，不占版面。",
        ],
        "02-home-today-log.jpg",
        "图 2  首页：今日记录列表",
    ),
    (
        "四、添加宠物与档案管理",
        [
            "首次使用时，首页引导添加宠物：填写宠物名、物种（猫 / 狗 / 其它）、品种、"
            "生日与性别。填写生日后，软件按免疫规范自动生成疫苗、驱虫、体检与洗澡"
            "美容的提醒计划。",
            "「档案」页以页签组织宠物资料：资料（品种、生日、年龄、性别、体重、"
            "个性特点）、健康（预防保健台账、体重趋势、过敏与病史）、记录（时间线）、"
            "回忆（照片相册）与费用。点击右上角「编辑」可修改档案信息与头像。",
        ],
        "03-profile-info.jpg",
        "图 3  档案页：基本信息与个性特点",
    ),
    (
        "五、记录一笔健康记录",
        [
            "点击首页「快捷记录」中的任意图标，或在「档案 → 记录」页点击右下角「+」，"
            "打开记录表单。表单顶部为类型选择（体重、核心疫苗、体内驱虫、体外驱虫、"
            "用药、就诊、洗澡美容、喂食、饮水、排便、睡眠、笔记），中部按类型展示对应"
            "输入项，底部点击「保存记录」提交。",
            "记录时间默认为当前时间，可点击时间栏回拨，用于补录历史事件（如上个月的"
            "疫苗接种）。",
        ],
        "08-add-record.jpg",
        "图 4  记一笔：类型选择与体重滑块",
    ),
    (
        "六、记录列表与体重趋势",
        [
            "「记录」页顶部为搜索框与类型筛选（全部、体重、核心疫苗、体内驱虫、"
            "体外驱虫等），其下「体重趋势」按时间绘制体重折线并标注最新数值；"
            "「今天」列表展示当天全部记录。",
            "点击任意一条记录即可进入该记录的详情页。",
        ],
        "04-records-trend.jpg",
        "图 5  记录页：体重趋势与当天记录",
    ),
    (
        "七、记录详情、照片与文档原件",
        [
            "详情页展示该记录的发生时间、录入时间与备注，可通过「改时间」修正补录"
            "事件的发生时间，也可删除该记录。",
            "「照片」区可拍照或从相册选择照片，补充药盒、处方、单据等图像资料；"
            "「文档原件」区可添加 PDF、Word、图片等文档（如疫苗本、化验单、保单），"
            "单个文件不超过 20MB。文档原件仅保存在本机，不上传服务器；点击文档可"
            "调出系统分享面板，交给其它应用打开或发送给兽医。",
        ],
        "05-record-detail-doc.jpg",
        "图 6  记录详情：照片与文档原件",
    ),
    (
        "八、费用追踪",
        [
            "「档案 → 费用」页签用于记录养宠支出。点击「记一笔花费」，填写金额、"
            "分类（主粮零食、就诊用药、疫苗、驱虫、洗澡美容、用品、寄养托运、其他）"
            "与消费日期后保存。",
            "页面上方汇总本月支出、累计支出与月均支出；中部为近半年支出趋势柱状图；"
            "下方为本月分类占比与最近支出明细，明细中的条目可删除。",
        ],
        "07-expense-tab.jpg",
        "图 7  费用页签：本月汇总与趋势",
    ),
    (
        "九、数据同步与账号",
        [
            "「我的」页提供：我的宠物（多宠物管理与添加）、备案号展示、数据同步、"
            "联系方式与关于（版本号、隐私政策、用户协议）。",
            "数据同步支持手机号验证码登录与密码登录。登录后点击「立即同步」，本地"
            "数据加密上传并拉取云端数据，页面显示上次同步时间与待上传条数。未登录"
            "也可以离线记录，登录后本地数据自动过户到账号名下。",
        ],
        "06-me-sync.jpg",
        "图 8  我的：账号、数据同步与关于",
    ),
    (
        "十、运行环境",
        [
            "本软件运行于 Android 7.0（API 24）及以上版本；建议预留 200MB 以上存储"
            "空间。照片与文档原件保存在本机应用专属目录中，卸载应用前请自行备份。",
        ],
        None,
        "",
    ),
]


def main():
    pdf = FPDF(format="A4")
    pdf.set_margins(20, 18, 20)
    pdf.set_auto_page_break(True, margin=18)
    pdf.add_font("hei", "", FONT)
    pdf.alias_nb_pages()

    avail_w = pdf.w - pdf.l_margin - pdf.r_margin

    def header():
        pdf.set_font("hei", size=10)
        pdf.set_text_color(60, 60, 60)
        pdf.cell(
            avail_w, 6,
            f"{SOFT_NAME} {SOFT_VER}（操作说明书）    "
            f"第 {pdf.page_no()} 页 / 共 {{nb}} 页",
            align="C", new_x="LMARGIN", new_y="NEXT",
        )
        pdf.set_text_color(0, 0, 0)
        pdf.ln(2)

    pdf.add_page()
    header()

    for title, paras, img, caption in SECTIONS:
        # 标题
        pdf.set_font("hei", size=13)
        pdf.multi_cell(avail_w, 8, title, new_x="LMARGIN", new_y="NEXT")
        pdf.ln(1)

        # 正文
        pdf.set_font("hei", size=10.5)
        for p in paras:
            pdf.multi_cell(avail_w, 6.2, p)
            pdf.ln(1.5)

        # 截图
        if img:
            path = os.path.join(SHOTS, img)
            with Image.open(path) as im:
                w_px, h_px = im.size
            h_mm = IMG_W * h_px / w_px
            if pdf.get_y() + h_mm + 14 > pdf.h - pdf.b_margin:
                pdf.add_page()
                header()
            x = (pdf.w - IMG_W) / 2
            pdf.image(path, x=x, w=IMG_W)
            pdf.set_font("hei", size=9.5)
            pdf.set_text_color(90, 90, 90)
            pdf.cell(avail_w, 7, caption, align="C", new_x="LMARGIN", new_y="NEXT")
            pdf.set_text_color(0, 0, 0)

        pdf.ln(3)

    pdf.output(OUT)
    print(f"输出: {OUT}")
    print(f"页数: {pdf.page}")


if __name__ == "__main__":
    sys.exit(main())
