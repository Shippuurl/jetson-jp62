#!/usr/bin/env python3
"""生成多语言左右分栏页（zh / en / ja / de / fr / ko）。

设计约束（用户要求）：
  - 不要顶部导航条：语言切换放在左栏底部
  - 中间严格对半：grid 1fr 1fr，无 gap，右栏 border-left 正好落在 50%
  - 纯白极简，只有风险信息用色（caution #ad6800 / danger #a83224）

用法：python3 build/build_i18n.py       # 输出 index.html + index.<lang>.html
"""
import os, sys
from i18n_recovery import REC, SOURCES

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LANGS = [
    ("zh", "zh-CN", "index.html", "中文", "index.html"),
    ("en", "en", "index.en.html", "English", "index.en.html"),
    ("ja", "ja", "index.ja.html", "日本語", "index.ja.html"),
    ("de", "de", "index.de.html", "Deutsch", "index.de.html"),
    ("fr", "fr", "index.fr.html", "Français", "index.fr.html"),
    ("ko", "ko", "index.ko.html", "한국어", "index.ko.html"),
]

MIT = """MIT License

Copyright (c) 2026 Shippuurl

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""

# ---------------------------------------------------------------- 文案
T = {
"zh": dict(
    title="A2VEC · Jetson 维护工具",
    desc="A2VEC Jetson 命令行维护工具：环境检查、QSPI 固件刷写、NVMe 整机刷写。提供源码、准备清单、操作手册与 MIT 许可。",
    meta="FIELD TOOLS / JETSON",
    kicker="维护工具 · 01",
    h1="Jetson 固件维护脚本",
    intro="通过 Bash 调用 NVIDIA 刷写工具，执行环境检查、资源准备、QSPI 或 NVMe 刷写。面向 Jetson Orin 系列；具体支持范围以所选 BSP、板型配置及厂商文档为准。",
    dl="下载脚本 ↓", guide="详细使用说明 ↗", gh="GitHub 源码 ↗",
    s1="获取与运行",
    s1muted="下载后审阅脚本，再查看参数或进入交互菜单。刷写前请显式选择经核对的 L4T 版本。",
    ccomment="# 审阅脚本后执行",
    caut_t="刷写前确认",
    caut_b="QSPI 模式写入启动固件，错误配置可能导致无法启动；NVMe 模式会重写目标存储并清除数据。请备份数据，确认载板适配、稳定供电和恢复路径。所需磁盘空间以运行时预检查为准。",
    s2="脚本模式",
    modes=[("detect", "检测运行环境及设备状态，不执行固件刷写。"),
           ("prep", "下载并准备 BSP；可选准备 sample rootfs。"),
           ("qspi", "刷写 QSPI 启动固件，不以重写系统盘为目标。"),
           ("nvme", "**重写目标存储，清除数据。** 调用官方 initrd flash。"),
           ("target", "在 Jetson 上通过 apt 更新软件包；不等同于 QSPI 升级。")],
    usage="用法：<code>bash jetson-jp62.sh --mode &lt;模式&gt;</code><br>版本、诊断、串口与离线参数见 <code>--help</code> 或<a href=\"guide.html\">操作手册</a>。",
    prep_meta="准备工作",
    prep_h2="刷写前需要准备",
    items=[("Jetson 主板", "Orin Nano / Orin NX（t234）。实际模组与载板以 EEPROM 读数（Board ID / SKU）为准。"),
           ("电源适配器", "19V 桶形供电。刷写与 recovery 期间不要仅依赖 USB-C 供电。"),
           ("USB-C 数据线", "把板子以 recovery（APX）方式连到主机。需支持数据传输，纯充电线无法被识别。"),
           ("跳线帽", "短接 FC REC 与 GND 进入 recovery。短接位置以载板丝印为准，DevKit 为 12 针排针的 FC REC / GND（第 9、10 脚）。")],
    note_t="上电约 2 秒后拔掉跳线帽。",
    note_risk="不拔会导致下次上电继续进入 recovery。",
    note_seq="顺序：断电 → 戴跳线帽 → 上电 → 约 2 秒后拔下 → 主机 <code>lsusb</code> 出现 <code>0955:7523</code> 或 <code>0955:7623</code>（APX）。",
    figs=["Jetson 主板：40-pin 排针、USB-C 与 19V 供电口位置。",
          "跳线帽：用于短接 FC REC 与 GND。",
          "跳线帽接入位置：保持短接状态下上电，主机检测到设备后拔下。"],
    prep_close="准备完成后回到左栏「获取与运行」，先执行 <code>--mode detect</code> 再决定是否刷写。",
    legal_sum="法律声明 · MIT License · 第三方许可",
    legal_h2="法律声明与许可",
    legal=[
        "本工具为 A2VEC 品牌下的独立维护辅助项目，不是 NVIDIA 官方产品，与 NVIDIA 无隶属、授权代理或背书关系。NVIDIA、Jetson 和 JetPack 为 NVIDIA Corporation 的商标。",
        "脚本与文档依据 <a href=\"LICENSE\">MIT License</a> 提供；再分发时须保留版权与许可声明。原版权声明为 Copyright (c) 2026 Shippuurl，品牌展示不改变原版权归属。MIT 不授予第三方商标或 NVIDIA 软件的使用权。",
        "软件按“现状”（AS IS）提供。在适用法律允许的最大范围内，不提供明示或默示担保，包括适销性、特定用途适用性及不侵权担保；作者及版权持有人的责任限制以 MIT 原文为准。本声明不排除或限制适用法律不得排除或限制的责任。",
        "公开发布的脚本不包含 NVIDIA 固件、引导程序或专有 SDK。运行时取得的第三方组件受其随附许可及 <a href=\"https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/SoftwarePackagesAndTheUpdateMechanism.html\">NVIDIA 软件包说明</a>约束；使用者应在下载、使用或再分发前核对对应版本许可。对本工具的确认不替代第三方许可要求。",
        "使用者应确认设备操作权限、备份及恢复方案，并依据官方文档核对模组、载板、BSP 和系统版本。预检查通过或下载地址可用不构成兼容性、安全性或刷写成功保证。第三方载板须以其厂商适配资料为准。"],
    mit_h2="MIT License · 原文",
    foot_l="A2VEC · 独立维护工具 / 非 NVIDIA 官方产品",
    foot_r="MIT License · © 2026 Shippuurl",
    lang_label="语言",
),

"en": dict(
    title="A2VEC · Jetson Maintenance Tool",
    desc="A2VEC Jetson command-line maintenance tool: environment checks, QSPI firmware flashing, full NVMe flashing. Source, prerequisites, manual and MIT license.",
    meta="FIELD TOOLS / JETSON",
    kicker="MAINTENANCE TOOL · 01",
    h1="Jetson Firmware Maintenance Script",
    intro="A Bash front-end to the NVIDIA flashing tools: environment checks, resource preparation, QSPI or NVMe flashing. Targets the Jetson Orin family; the supported range depends on the selected BSP, board configuration and vendor documentation.",
    dl="Download script ↓", guide="Detailed guide ↗", gh="Source on GitHub ↗",
    s1="Get and run",
    s1muted="Review the script after downloading, then check the options or open the interactive menu. Select a verified L4T version explicitly before flashing.",
    ccomment="# after reviewing the script",
    caut_t="Before flashing",
    caut_b="QSPI mode writes boot firmware; a wrong configuration can leave the board unbootable. NVMe mode rewrites the target storage and erases data. Back up your data and confirm carrier support, stable power and a recovery path. Required disk space is determined by the runtime pre-check.",
    s2="Script modes",
    modes=[("detect", "Inspect the host and device state; performs no flashing."),
           ("prep", "Download and prepare the BSP; optionally prepare a sample rootfs."),
           ("qspi", "Flash QSPI boot firmware; the system disk is not the target."),
           ("nvme", "**Rewrites target storage, erases data.** Uses the official initrd flash."),
           ("target", "Update packages on the Jetson via apt; not equivalent to a QSPI upgrade.")],
    usage="Usage: <code>bash jetson-jp62.sh --mode &lt;mode&gt;</code><br>Version, diagnostics, UART and offline options: see <code>--help</code> or the <a href=\"guide.html\">manual</a>.",
    prep_meta="PREPARATION",
    prep_h2="What you need before flashing",
    items=[("Jetson board", "Orin Nano / Orin NX (t234). Module and carrier are confirmed by the EEPROM reading (Board ID / SKU)."),
           ("Power supply", "19 V barrel input. Do not rely on USB-C power alone while flashing or in recovery."),
           ("USB-C data cable", "Connects the board to the host in recovery (APX) mode. Must carry data; charge-only cables are not detected."),
           ("Jumper cap", "Shorts FC REC to GND to enter recovery. Follow the carrier silkscreen; on the DevKit it is the 12-pin header, FC REC / GND (pins 9 and 10).")],
    note_t="Remove the jumper cap about 2 s after power-on.",
    note_risk="Leaving it on makes the board enter recovery again at the next power-up.",
    note_seq="Order: power off → fit the cap → power on → remove it after ~2 s → <code>lsusb</code> on the host shows <code>0955:7523</code> or <code>0955:7623</code> (APX).",
    figs=["Jetson board: 40-pin header, USB-C and 19 V input.",
          "Jumper cap: shorts FC REC to GND.",
          "Jumper cap in place: power on while shorted, remove it once the host detects the device."],
    prep_close="When ready, go back to “Get and run” on the left and run <code>--mode detect</code> before deciding whether to flash.",
    legal_sum="Legal notice · MIT License · Third-party licences",
    legal_h2="Legal notice and licence",
    legal=[
        "This tool is an independent maintenance helper published under the A2VEC brand. It is not an NVIDIA product and has no affiliation with, authorisation from or endorsement by NVIDIA. NVIDIA, Jetson and JetPack are trademarks of NVIDIA Corporation.",
        "The script and documentation are provided under the <a href=\"LICENSE\">MIT License</a>; redistributions must keep the copyright and licence notice. The original copyright notice is Copyright (c) 2026 Shippuurl; brand presentation does not change that ownership. MIT grants no rights to third-party trademarks or NVIDIA software.",
        "The software is provided “AS IS”. To the maximum extent permitted by applicable law no express or implied warranty is given, including merchantability, fitness for a particular purpose and non-infringement; liability is limited as stated in the MIT text. This notice does not exclude liability that applicable law does not allow to be excluded.",
        "The published script contains no NVIDIA firmware, bootloader or proprietary SDK. Third-party components obtained at runtime are governed by their own licences and the <a href=\"https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/SoftwarePackagesAndTheUpdateMechanism.html\">NVIDIA software package documentation</a>; check the licence of the matching version before downloading, using or redistributing. Acknowledgement of this tool does not replace third-party licence requirements.",
        "Users must confirm they are authorised to operate the device, prepare backups and a recovery plan, and verify module, carrier, BSP and system versions against official documentation. A passing pre-check or an available download URL is not a guarantee of compatibility, safety or flashing success. Third-party carriers are governed by their vendor's adaptation material."],
    mit_h2="MIT License · full text",
    foot_l="A2VEC · Independent maintenance tool / not an NVIDIA product",
    foot_r="MIT License · © 2026 Shippuurl",
    lang_label="Language",
),

"ja": dict(
    title="A2VEC · Jetson メンテナンスツール",
    desc="A2VEC の Jetson コマンドラインメンテナンスツール。環境チェック、QSPI ファームウェア書き込み、NVMe フル書き込み。ソース、準備物、手順書、MIT ライセンスを公開。",
    meta="FIELD TOOLS / JETSON",
    kicker="メンテナンスツール · 01",
    h1="Jetson ファームウェア メンテナンススクリプト",
    intro="NVIDIA の書き込みツールを Bash から呼び出し、環境チェック・リソース準備・QSPI または NVMe 書き込みを行います。対象は Jetson Orin シリーズ。対応範囲は選択した BSP、ボード構成、ベンダーのドキュメントに依存します。",
    dl="スクリプトをダウンロード ↓", guide="詳細手順 ↗", gh="GitHub ソース ↗",
    s1="入手と実行",
    s1muted="ダウンロード後にスクリプトを確認し、オプションを確認するか対話メニューを開いてください。書き込み前に、確認済みの L4T バージョンを明示的に選択します。",
    ccomment="# スクリプトを確認してから実行",
    caut_t="書き込み前の確認",
    caut_b="QSPI モードは起動ファームウェアを書き込むため、設定を誤ると起動できなくなる可能性があります。NVMe モードは対象ストレージを書き換え、データを消去します。データをバックアップし、キャリアの適合性、安定した電源、復旧手順を確認してください。必要なディスク容量は実行時の事前チェックで判定されます。",
    s2="スクリプトのモード",
    modes=[("detect", "実行環境とデバイス状態を確認します。書き込みは行いません。"),
           ("prep", "BSP をダウンロードして準備します。sample rootfs の準備も可能です。"),
           ("qspi", "QSPI 起動ファームウェアを書き込みます。システムディスクの書き換えは目的ではありません。"),
           ("nvme", "**対象ストレージを書き換え、データを消去します。** 公式 initrd flash を呼び出します。"),
           ("target", "Jetson 上で apt によりパッケージを更新します。QSPI の更新とは異なります。")],
    usage="使い方: <code>bash jetson-jp62.sh --mode &lt;モード&gt;</code><br>バージョン、診断、UART、オフラインの各オプションは <code>--help</code> または<a href=\"guide.html\">手順書</a>を参照してください。",
    prep_meta="準備",
    prep_h2="書き込み前に用意するもの",
    items=[("Jetson ボード", "Orin Nano / Orin NX（t234）。モジュールとキャリアは EEPROM の読み取り値（Board ID / SKU）で確認します。"),
           ("電源アダプター", "19V のバレルジャック給電。書き込み中や recovery 中は USB-C 給電だけに頼らないでください。"),
           ("USB-C データケーブル", "ボードを recovery（APX）でホストに接続します。データ通信対応が必要で、充電専用ケーブルは認識されません。"),
           ("ジャンパキャップ", "FC REC と GND を短絡して recovery に入ります。位置はキャリアのシルクを確認してください。DevKit では 12 ピンヘッダの FC REC / GND（9・10 番ピン）です。")],
    note_t="電源投入の約 2 秒後にジャンパキャップを外してください。",
    note_risk="外さないと、次回の電源投入時も recovery に入ります。",
    note_seq="手順: 電源オフ → キャップ装着 → 電源オン → 約 2 秒後に取り外す → ホストの <code>lsusb</code> に <code>0955:7523</code> または <code>0955:7623</code>（APX）が表示される。",
    figs=["Jetson ボード: 40 ピンヘッダ、USB-C、19V 入力。",
          "ジャンパキャップ: FC REC と GND を短絡します。",
          "ジャンパキャップ装着位置: 短絡したまま電源を入れ、ホストが認識したら外します。"],
    prep_close="準備ができたら左欄の「入手と実行」に戻り、まず <code>--mode detect</code> を実行してから書き込むか判断してください。",
    legal_sum="法的通知 · MIT License · 第三者ライセンス",
    legal_h2="法的通知とライセンス",
    legal=[
        "本ツールは A2VEC ブランドで公開される独立したメンテナンス補助プロジェクトであり、NVIDIA の公式製品ではありません。NVIDIA との提携、代理、推奨関係はありません。NVIDIA、Jetson、JetPack は NVIDIA Corporation の商標です。",
        "スクリプトとドキュメントは <a href=\"LICENSE\">MIT License</a> で提供されます。再配布時は著作権表示とライセンス表示を保持してください。原著作権表示は Copyright (c) 2026 Shippuurl であり、ブランド表示は帰属を変更しません。MIT は第三者の商標や NVIDIA ソフトウェアの使用権を許諾しません。",
        "本ソフトウェアは「現状のまま」（AS IS）提供されます。適用法が許す最大限の範囲で、明示または黙示の保証（商品性、特定目的への適合性、非侵害を含む）を行いません。責任の制限は MIT 原文に従います。本通知は、適用法上排除できない責任を排除するものではありません。",
        "公開スクリプトには NVIDIA のファームウェア、ブートローダー、専有 SDK は含まれません。実行時に取得する第三者コンポーネントは、その付属ライセンスおよび <a href=\"https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/SoftwarePackagesAndTheUpdateMechanism.html\">NVIDIA ソフトウェアパッケージの説明</a>に従います。ダウンロード、使用、再配布の前に該当バージョンのライセンスを確認してください。本ツールへの同意は第三者ライセンスの要件を代替しません。",
        "利用者は、デバイスの操作権限、バックアップ、復旧手順を確認し、モジュール、キャリア、BSP、システムのバージョンを公式ドキュメントに照らして確認してください。事前チェックの通過やダウンロード URL の可用性は、互換性・安全性・書き込み成功を保証しません。第三者キャリアはベンダーの適合資料に従います。"],
    mit_h2="MIT License · 原文",
    foot_l="A2VEC · 独立メンテナンスツール / NVIDIA 公式製品ではありません",
    foot_r="MIT License · © 2026 Shippuurl",
    lang_label="言語",
),

"de": dict(
    title="A2VEC · Jetson-Wartungswerkzeug",
    desc="Kommandozeilen-Werkzeug von A2VEC für Jetson: Umgebungsprüfung, QSPI-Firmware-Flash, vollständiges NVMe-Flash. Quellcode, Voraussetzungen, Handbuch und MIT-Lizenz.",
    meta="FIELD TOOLS / JETSON",
    kicker="WARTUNGSWERKZEUG · 01",
    h1="Jetson-Firmware-Wartungsskript",
    intro="Ein Bash-Frontend für die Flash-Werkzeuge von NVIDIA: Umgebungsprüfung, Vorbereitung der Ressourcen, QSPI- oder NVMe-Flash. Ziel ist die Jetson-Orin-Reihe; der unterstützte Umfang hängt vom gewählten BSP, der Board-Konfiguration und der Herstellerdokumentation ab.",
    dl="Skript herunterladen ↓", guide="Ausführliche Anleitung ↗", gh="Quellcode auf GitHub ↗",
    s1="Beziehen und ausführen",
    s1muted="Nach dem Download das Skript prüfen, dann Optionen ansehen oder das interaktive Menü öffnen. Vor dem Flashen eine geprüfte L4T-Version explizit auswählen.",
    ccomment="# nach Prüfung des Skripts ausführen",
    caut_t="Vor dem Flashen prüfen",
    caut_b="Der QSPI-Modus schreibt Boot-Firmware; eine falsche Konfiguration kann das Board unstartbar machen. Der NVMe-Modus überschreibt den Zielspeicher und löscht Daten. Daten sichern, Trägerkompatibilität, stabile Stromversorgung und einen Wiederherstellungsweg bestätigen. Der benötigte Speicherplatz ergibt sich aus der Vorabprüfung zur Laufzeit.",
    s2="Skriptmodi",
    modes=[("detect", "Prüft Host- und Gerätezustand; kein Flashvorgang."),
           ("prep", "BSP herunterladen und vorbereiten; optional ein Sample-Rootfs."),
           ("qspi", "Schreibt QSPI-Boot-Firmware; die Systemplatte ist nicht das Ziel."),
           ("nvme", "**Überschreibt den Zielspeicher, löscht Daten.** Nutzt den offiziellen initrd-Flash."),
           ("target", "Aktualisiert Pakete auf dem Jetson per apt; nicht gleichwertig zu einem QSPI-Upgrade.")],
    usage="Aufruf: <code>bash jetson-jp62.sh --mode &lt;Modus&gt;</code><br>Version, Diagnose, UART und Offline-Optionen: siehe <code>--help</code> oder das <a href=\"guide.html\">Handbuch</a>.",
    prep_meta="VORBEREITUNG",
    prep_h2="Was vor dem Flashen bereitsteht",
    items=[("Jetson-Board", "Orin Nano / Orin NX (t234). Modul und Trägerboard werden über den EEPROM-Auslesewert (Board ID / SKU) bestätigt."),
           ("Netzteil", "19-V-Hohlstecker. Während Flash und Recovery nicht nur USB-C als Stromquelle nutzen."),
           ("USB-C-Datenkabel", "Verbindet das Board im Recovery(APX)-Modus mit dem Host. Muss Daten übertragen; reine Ladekabel werden nicht erkannt."),
           ("Jumper-Kappe", "Überbrückt FC REC und GND für den Recovery-Modus. Position laut Bestückungsdruck; beim DevKit der 12-polige Header, FC REC / GND (Pin 9 und 10).")],
    note_t="Jumper-Kappe etwa 2 s nach dem Einschalten abziehen.",
    note_risk="Bleibt sie gesteckt, startet das Board beim nächsten Einschalten erneut in den Recovery-Modus.",
    note_seq="Reihenfolge: ausschalten → Kappe stecken → einschalten → nach ~2 s abziehen → <code>lsusb</code> am Host zeigt <code>0955:7523</code> oder <code>0955:7623</code> (APX).",
    figs=["Jetson-Board: 40-Pin-Header, USB-C und 19-V-Eingang.",
          "Jumper-Kappe: überbrückt FC REC und GND.",
          "Jumper-Kappe gesteckt: bei gesteckter Brücke einschalten, nach Erkennung am Host abziehen."],
    prep_close="Wenn alles bereit ist, zurück zu „Beziehen und ausführen“ und zuerst <code>--mode detect</code> ausführen, bevor über das Flashen entschieden wird.",
    legal_sum="Rechtliche Hinweise · MIT License · Lizenzhinweise Dritter",
    legal_h2="Rechtliche Hinweise und Lizenz",
    legal=[
        "Dieses Werkzeug ist ein unabhängiges Wartungshilfsprojekt unter der Marke A2VEC und kein offizielles NVIDIA-Produkt. Es besteht keine Zugehörigkeit, Vertretung oder Billigung durch NVIDIA. NVIDIA, Jetson und JetPack sind Marken der NVIDIA Corporation.",
        "Skript und Dokumentation werden unter der <a href=\"LICENSE\">MIT License</a> bereitgestellt; bei Weitergabe sind Copyright- und Lizenzhinweis beizubehalten. Der ursprüngliche Copyright-Hinweis lautet Copyright (c) 2026 Shippuurl; die Markendarstellung ändert die Urheberschaft nicht. MIT gewährt keine Rechte an Marken Dritter oder an NVIDIA-Software.",
        "Die Software wird „wie besehen“ (AS IS) bereitgestellt. Soweit gesetzlich zulässig, werden keine ausdrücklichen oder stillschweigenden Gewährleistungen übernommen, einschließlich Marktgängigkeit, Eignung für einen bestimmten Zweck und Nichtverletzung; die Haftung richtet sich nach dem MIT-Text. Dieser Hinweis schließt keine Haftung aus, die nach geltendem Recht nicht ausgeschlossen werden kann.",
        "Das veröffentlichte Skript enthält keine NVIDIA-Firmware, keinen Bootloader und kein proprietäres SDK. Zur Laufzeit bezogene Komponenten Dritter unterliegen deren Lizenzen sowie der <a href=\"https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/SoftwarePackagesAndTheUpdateMechanism.html\">NVIDIA-Dokumentation zu Softwarepaketen</a>; vor Download, Nutzung oder Weitergabe die Lizenz der passenden Version prüfen. Die Zustimmung zu diesem Werkzeug ersetzt keine Lizenzpflichten Dritter.",
        "Anwender müssen die Berechtigung zum Betrieb des Geräts, Backups und einen Wiederherstellungsplan sicherstellen und Modul, Trägerboard, BSP und Systemversion anhand offizieller Dokumentation prüfen. Eine bestandene Vorabprüfung oder eine erreichbare Download-URL ist keine Garantie für Kompatibilität, Sicherheit oder Flash-Erfolg. Für Trägerboards Dritter gilt die Anpassungsdokumentation des Herstellers."],
    mit_h2="MIT License · Volltext",
    foot_l="A2VEC · Unabhängiges Wartungswerkzeug / kein NVIDIA-Produkt",
    foot_r="MIT License · © 2026 Shippuurl",
    lang_label="Sprache",
),

"fr": dict(
    title="A2VEC · Outil de maintenance Jetson",
    desc="Outil en ligne de commande A2VEC pour Jetson : vérifications d'environnement, flash du firmware QSPI, flash NVMe complet. Code source, prérequis, manuel et licence MIT.",
    meta="FIELD TOOLS / JETSON",
    kicker="OUTIL DE MAINTENANCE · 01",
    h1="Script de maintenance du firmware Jetson",
    intro="Une interface Bash vers les outils de flash NVIDIA : vérification de l'environnement, préparation des ressources, flash QSPI ou NVMe. Cible la gamme Jetson Orin ; la couverture dépend du BSP choisi, de la configuration de la carte et de la documentation du fabricant.",
    dl="Télécharger le script ↓", guide="Guide détaillé ↗", gh="Source sur GitHub ↗",
    s1="Obtenir et exécuter",
    s1muted="Relisez le script après téléchargement, puis consultez les options ou ouvrez le menu interactif. Choisissez explicitement une version L4T vérifiée avant de flasher.",
    ccomment="# après relecture du script",
    caut_t="Avant de flasher",
    caut_b="Le mode QSPI écrit le firmware de démarrage ; une configuration erronée peut empêcher la carte de démarrer. Le mode NVMe réécrit le stockage cible et efface les données. Sauvegardez vos données et confirmez la compatibilité de la carte porteuse, l'alimentation stable et un moyen de récupération. L'espace disque requis est déterminé par la vérification au lancement.",
    s2="Modes du script",
    modes=[("detect", "Inspecte l'hôte et l'état de l'appareil ; aucun flash."),
           ("prep", "Télécharge et prépare le BSP ; préparation facultative d'un sample rootfs."),
           ("qspi", "Écrit le firmware de démarrage QSPI ; le disque système n'est pas la cible."),
           ("nvme", "**Réécrit le stockage cible, efface les données.** Utilise le flash initrd officiel."),
           ("target", "Met à jour les paquets sur le Jetson via apt ; ne remplace pas une mise à niveau QSPI.")],
    usage="Usage : <code>bash jetson-jp62.sh --mode &lt;mode&gt;</code><br>Version, diagnostics, UART et options hors ligne : voir <code>--help</code> ou le <a href=\"guide.html\">manuel</a>.",
    prep_meta="PRÉPARATION",
    prep_h2="Ce qu'il faut avant de flasher",
    items=[("Carte Jetson", "Orin Nano / Orin NX (t234). Module et carte porteuse sont confirmés par la lecture EEPROM (Board ID / SKU)."),
           ("Alimentation", "Entrée jack 19 V. Pendant le flash ou le mode recovery, ne pas dépendre uniquement de l'alimentation USB-C."),
           ("Câble USB-C de données", "Relie la carte à l'hôte en mode recovery (APX). Doit transmettre des données ; un câble de charge seul n'est pas détecté."),
           ("Cavalier", "Court-circuite FC REC et GND pour entrer en recovery. Position selon la sérigraphie ; sur le DevKit, connecteur 12 broches, FC REC / GND (broches 9 et 10).")],
    note_t="Retirez le cavalier environ 2 s après la mise sous tension.",
    note_risk="S'il reste en place, la carte redémarre en recovery à la prochaine mise sous tension.",
    note_seq="Ordre : couper l'alimentation → poser le cavalier → remettre sous tension → retirer après ~2 s → <code>lsusb</code> sur l'hôte affiche <code>0955:7523</code> ou <code>0955:7623</code> (APX).",
    figs=["Carte Jetson : connecteur 40 broches, USB-C et entrée 19 V.",
          "Cavalier : court-circuite FC REC et GND.",
          "Cavalier en place : mise sous tension avec le shunt, retrait dès que l'hôte détecte l'appareil."],
    prep_close="Une fois prêt, revenez à « Obtenir et exécuter » et lancez <code>--mode detect</code> avant de décider du flash.",
    legal_sum="Mentions légales · MIT License · Licences tierces",
    legal_h2="Mentions légales et licence",
    legal=[
        "Cet outil est un projet d'assistance à la maintenance indépendant publié sous la marque A2VEC ; ce n'est pas un produit officiel NVIDIA. Aucun lien d'affiliation, de représentation ou d'approbation avec NVIDIA n'existe. NVIDIA, Jetson et JetPack sont des marques de NVIDIA Corporation.",
        "Le script et la documentation sont fournis sous <a href=\"LICENSE\">licence MIT</a> ; toute redistribution doit conserver la mention de copyright et de licence. La mention d'origine est Copyright (c) 2026 Shippuurl ; la présentation de marque ne modifie pas cette attribution. MIT n'accorde aucun droit sur les marques de tiers ni sur les logiciels NVIDIA.",
        "Le logiciel est fourni « en l'état » (AS IS). Dans les limites permises par la loi, aucune garantie expresse ou implicite n'est donnée, y compris de qualité marchande, d'adaptation à un usage particulier et d'absence de contrefaçon ; la responsabilité est limitée conformément au texte MIT. Cette mention n'exclut pas les responsabilités que la loi applicable interdit d'exclure.",
        "Le script publié ne contient ni firmware, ni bootloader, ni SDK propriétaire NVIDIA. Les composants tiers obtenus à l'exécution relèvent de leurs propres licences et de la <a href=\"https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/SoftwarePackagesAndTheUpdateMechanism.html\">documentation des paquets logiciels NVIDIA</a> ; vérifiez la licence de la version concernée avant tout téléchargement, usage ou redistribution. L'acceptation de cet outil ne remplace pas les obligations de licence tierce.",
        "L'utilisateur doit vérifier qu'il est autorisé à manipuler l'appareil, préparer une sauvegarde et un plan de récupération, et confirmer module, carte porteuse, BSP et version système à partir de la documentation officielle. Une vérification réussie ou une URL disponible ne garantit ni la compatibilité, ni la sécurité, ni la réussite du flash. Les cartes porteuses tierces relèvent de la documentation d'adaptation de leur fabricant."],
    mit_h2="MIT License · texte intégral",
    foot_l="A2VEC · Outil de maintenance indépendant / produit non officiel NVIDIA",
    foot_r="MIT License · © 2026 Shippuurl",
    lang_label="Langue",
),

"ko": dict(
    title="A2VEC · Jetson 유지보수 도구",
    desc="A2VEC Jetson 명령줄 유지보수 도구: 환경 점검, QSPI 펌웨어 플래시, NVMe 전체 플래시. 소스, 준비물, 설명서, MIT 라이선스 제공.",
    meta="FIELD TOOLS / JETSON",
    kicker="유지보수 도구 · 01",
    h1="Jetson 펌웨어 유지보수 스크립트",
    intro="NVIDIA 플래시 도구를 Bash로 호출해 환경 점검, 리소스 준비, QSPI 또는 NVMe 플래시를 수행합니다. 대상은 Jetson Orin 시리즈이며, 지원 범위는 선택한 BSP, 보드 구성, 벤더 문서에 따라 달라집니다.",
    dl="스크립트 다운로드 ↓", guide="상세 사용 설명서 ↗", gh="GitHub 소스 ↗",
    s1="받기와 실행",
    s1muted="다운로드 후 스크립트를 검토하고 옵션을 확인하거나 대화형 메뉴를 엽니다. 플래시 전에 확인된 L4T 버전을 명시적으로 선택하십시오.",
    ccomment="# 스크립트 검토 후 실행",
    caut_t="플래시 전 확인",
    caut_b="QSPI 모드는 부팅 펌웨어를 기록하므로 설정이 잘못되면 부팅이 되지 않을 수 있습니다. NVMe 모드는 대상 저장 장치를 다시 쓰고 데이터를 지웁니다. 데이터를 백업하고 캐리어 호환성, 안정적인 전원, 복구 절차를 확인하십시오. 필요한 디스크 공간은 실행 시 사전 점검으로 판정됩니다.",
    s2="스크립트 모드",
    modes=[("detect", "실행 환경과 장치 상태를 점검합니다. 플래시는 하지 않습니다."),
           ("prep", "BSP를 내려받아 준비합니다. sample rootfs 준비는 선택 사항입니다."),
           ("qspi", "QSPI 부팅 펌웨어를 기록합니다. 시스템 디스크 재작성이 목적이 아닙니다."),
           ("nvme", "**대상 저장 장치를 다시 쓰고 데이터를 삭제합니다.** 공식 initrd flash를 사용합니다."),
           ("target", "Jetson에서 apt로 패키지를 업데이트합니다. QSPI 업그레이드와 같지 않습니다.")],
    usage="사용법: <code>bash jetson-jp62.sh --mode &lt;모드&gt;</code><br>버전, 진단, UART, 오프라인 옵션은 <code>--help</code> 또는 <a href=\"guide.html\">설명서</a>를 참고하십시오.",
    prep_meta="준비물",
    prep_h2="플래시 전 준비물",
    items=[("Jetson 보드", "Orin Nano / Orin NX(t234). 모듈과 캐리어는 EEPROM 판독값(Board ID / SKU)으로 확인합니다."),
           ("전원 어댑터", "19V 배럴 잭 전원. 플래시와 recovery 중에는 USB-C 전원에만 의존하지 마십시오."),
           ("USB-C 데이터 케이블", "보드를 recovery(APX) 모드로 호스트에 연결합니다. 데이터 전송을 지원해야 하며, 충전 전용 케이블은 인식되지 않습니다."),
           ("점퍼 캡", "FC REC와 GND를 단락해 recovery로 진입합니다. 위치는 캐리어 실크를 확인하십시오. DevKit은 12핀 헤더의 FC REC / GND(9·10번 핀)입니다.")],
    note_t="전원 인가 약 2초 후 점퍼 캡을 제거하십시오.",
    note_risk="제거하지 않으면 다음 전원 인가 시에도 recovery로 진입합니다.",
    note_seq="순서: 전원 차단 → 캡 장착 → 전원 인가 → 약 2초 후 제거 → 호스트 <code>lsusb</code>에 <code>0955:7523</code> 또는 <code>0955:7623</code>(APX) 표시.",
    figs=["Jetson 보드: 40핀 헤더, USB-C, 19V 입력.",
          "점퍼 캡: FC REC와 GND를 단락합니다.",
          "점퍼 캡 장착 위치: 단락 상태로 전원을 인가하고 호스트가 인식하면 제거합니다."],
    prep_close="준비가 끝나면 왼쪽 «받기와 실행»으로 돌아가 먼저 <code>--mode detect</code>를 실행한 뒤 플래시 여부를 결정하십시오.",
    legal_sum="법적 고지 · MIT License · 제3자 라이선스",
    legal_h2="법적 고지 및 라이선스",
    legal=[
        "이 도구는 A2VEC 브랜드로 공개되는 독립 유지보수 보조 프로젝트이며 NVIDIA 공식 제품이 아닙니다. NVIDIA와 제휴, 대리, 보증 관계가 없습니다. NVIDIA, Jetson, JetPack은 NVIDIA Corporation의 상표입니다.",
        "스크립트와 문서는 <a href=\"LICENSE\">MIT License</a>로 제공되며, 재배포 시 저작권 및 라이선스 고지를 유지해야 합니다. 원 저작권 고지는 Copyright (c) 2026 Shippuurl이며, 브랜드 표기는 귀속을 변경하지 않습니다. MIT는 제3자 상표나 NVIDIA 소프트웨어에 대한 사용권을 부여하지 않습니다.",
        "소프트웨어는 \"있는 그대로\"(AS IS) 제공됩니다. 적용 법률이 허용하는 최대 범위에서 상품성, 특정 목적 적합성, 비침해를 포함한 명시적·묵시적 보증을 하지 않으며, 책임 제한은 MIT 원문을 따릅니다. 본 고지는 적용 법률상 배제할 수 없는 책임을 배제하지 않습니다.",
        "공개 스크립트에는 NVIDIA 펌웨어, 부트로더, 전용 SDK가 포함되지 않습니다. 실행 시 획득하는 제3자 구성 요소는 해당 라이선스와 <a href=\"https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/SoftwarePackagesAndTheUpdateMechanism.html\">NVIDIA 소프트웨어 패키지 설명</a>의 적용을 받습니다. 다운로드, 사용, 재배포 전에 해당 버전의 라이선스를 확인하십시오. 본 도구에 대한 동의는 제3자 라이선스 요구를 대체하지 않습니다.",
        "사용자는 장치 조작 권한, 백업, 복구 계획을 확인하고 모듈, 캐리어, BSP, 시스템 버전을 공식 문서와 대조해야 합니다. 사전 점검 통과나 다운로드 URL의 가용성은 호환성, 안전성, 플래시 성공을 보장하지 않습니다. 제3자 캐리어는 해당 벤더의 적응 자료를 따릅니다."],
    mit_h2="MIT License · 원문",
    foot_l="A2VEC · 독립 유지보수 도구 / NVIDIA 공식 제품 아님",
    foot_r="MIT License · © 2026 Shippuurl",
    lang_label="언어",
),
}

CSS = """
*{box-sizing:border-box}html{color-scheme:light}
body{margin:0;background:#fff;color:#202428;font:15px/1.8 system-ui,-apple-system,"Segoe UI","Hiragino Sans","Microsoft YaHei","Malgun Gothic",sans-serif}
a{color:inherit;text-underline-offset:4px}a:hover{color:#925700}
a:focus-visible,button:focus-visible,summary:focus-visible{outline:2px solid #995b00;outline-offset:5px}
.meta{font:11.5px ui-monospace,SFMono-Regular,Consolas,monospace;letter-spacing:.09em;color:#626a72;text-transform:uppercase}
.muted{color:#626a72}
h1{font-size:clamp(25px,2.4vw,33px);font-weight:600;line-height:1.3;letter-spacing:-.03em;margin:10px 0 14px}
h2{font-size:16.5px;font-weight:650;margin:0 0 12px}
p{margin:10px 0}
/* ---- 正中严格对半 ---- */
.page{display:grid;grid-template-columns:1fr 1fr;align-items:start}
.pane{min-width:0;padding:40px clamp(22px,3.2vw,56px) 56px}
.pane.right{border-left:1px solid #e3e5e7}
.pane-top{display:flex;align-items:center;justify-content:space-between;gap:16px;min-height:38px;margin-bottom:26px}
.brand{display:flex;align-items:center;gap:11px;font-size:19px;font-weight:750;letter-spacing:.08em;text-decoration:none}
.brand img{width:38px;height:38px}
.intro{max-width:38em;color:#555e66}
.links{display:flex;flex-wrap:wrap;gap:10px 22px;margin:18px 0 0;font-size:14.5px}.primary{font-weight:650}
section{padding:26px 0;border-bottom:1px solid #e3e5e7}
section:last-of-type{border-bottom:0;padding-bottom:8px}
.command{border:1px solid #d7dbdf;margin-top:14px}
.command-head{display:flex;align-items:center;justify-content:space-between;padding:7px 14px;border-bottom:1px solid #e3e5e7;font-size:11.5px;color:#626a72}
button{background:#fff;color:#202428;border:1px solid #c7ccd1;padding:4px 11px;cursor:pointer;font:inherit;font-size:12.5px}
pre{padding:14px;margin:0;overflow:auto;font:12px/1.85 ui-monospace,SFMono-Regular,Consolas,monospace}
code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.92em}
.caution{border-left:3px solid #ad6800;padding-left:14px;margin:20px 0 0;font-size:13.5px}.caution strong{color:#925700}
.modes{margin:0}.modes div{display:grid;grid-template-columns:96px 1fr;gap:12px;padding:8px 0;border-bottom:1px solid #eff0f1}
.modes div:last-child{border:0}dt{font-family:ui-monospace,monospace;font-size:13.5px}dd{margin:0;color:#555e66;font-size:14px}
.danger{color:#a83224;font-weight:600}
details{font-size:13px;color:#555e66}summary{cursor:pointer;color:#202428;font-weight:600}
details h2{margin-top:18px}details pre{white-space:pre-wrap;padding:0;font-size:11px}
.status{min-height:20px;font-size:12px;color:#626a72}
/* ---- 右栏 ---- */
.col-wiki{font-size:14px;line-height:1.75}
.checklist{margin:14px 0 0;padding:0;list-style:none;counter-reset:c}
.checklist li{counter-increment:c;position:relative;padding:12px 0 12px 32px;border-bottom:1px solid #eff0f1}
.checklist li:last-child{border-bottom:0}
.checklist li::before{content:counter(c,decimal-leading-zero);position:absolute;left:0;top:13px;font:11px/1.9 ui-monospace,monospace;color:#9aa3ab;letter-spacing:.08em}
.checklist b{display:block;font-weight:650;font-size:14.5px;margin-bottom:2px}
.checklist span{color:#555e66;font-size:13.5px}
.inline-risk{color:#a83224;font-weight:600}
.note{border-left:3px solid #ad6800;padding-left:14px;margin:18px 0 0;font-size:13.5px;color:#555e66}.note b{color:#925700}
figure{margin:20px 0 0}figure img{display:block;width:100%;height:auto;border:1px solid #e3e5e7}
figcaption{margin-top:8px;font-size:12px;color:#626a72;line-height:1.6}
.gallery figure+figure{margin-top:16px}
.col-wiki h3{font-size:14.5px;font-weight:650;margin:26px 0 10px;padding-top:18px;border-top:1px solid #e3e5e7}
.method{margin:0 0 14px}
.method-t{margin:0 0 6px;font-size:13.5px;color:#202428}
.method-t b{display:inline-block;min-width:16px;font-weight:650;color:#9aa3ab;font-family:ui-monospace,monospace;font-size:12px}
.steps{margin:0;padding:0 0 0 20px;color:#555e66;font-size:13.5px;line-height:1.7}
.steps li{margin:2px 0}
.sources{margin:16px 0 0;font-size:12.5px;color:#626a72;display:grid;gap:4px}
.sources a{color:#555e66}
.sources .meta{display:block;margin-bottom:2px}
/* ---- 语言切换（放在栏底，不做顶部导航）---- */
.lang{display:flex;flex-wrap:wrap;align-items:center;gap:6px 14px;margin:26px 0 0;padding-top:16px;border-top:1px solid #e3e5e7;font-size:13px}
.lang .meta{margin-right:4px}
.lang a{text-decoration:none;border-bottom:1px solid #d7dbdf;padding-bottom:1px}
.lang a:hover{border-color:#925700}
.lang [aria-current]{color:#202428;font-weight:650}
footer{padding:0;margin:22px 0 0;font-size:11.5px;color:#626a72;display:flex;flex-wrap:wrap;justify-content:space-between;gap:10px}
/* ---- 移动端：单栏堆叠 ---- */
@media(min-width:921px){
  .page{min-height:100vh}
  .pane{height:100vh;overflow-y:auto;overscroll-behavior:contain;scrollbar-gutter:stable}
}
@media(max-width:920px){
  .page{grid-template-columns:1fr}
  .pane{padding:28px 20px 40px;height:auto;overflow:visible}
  .pane.right{border-left:0;border-top:1px solid #e3e5e7}
  .pane-top{margin-bottom:18px;min-height:32px}
  .brand{font-size:17px}.brand img{width:34px;height:34px}
  .modes div{grid-template-columns:74px 1fr;gap:10px}
  h1{font-size:24px}
}
"""

TPL = """<!doctype html>
<html lang="{lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title><meta name="description" content="{desc}">
<link rel="icon" href="a2vec-logo.svg" type="image/svg+xml">
{alt}
<style>{css}</style></head>
<body>
<div class="page">

<section class="pane left">
  <div class="pane-top">
    <a class="brand" href="{self_href}" aria-label="A2VEC"><img src="a2vec-logo.svg" alt="" width="38" height="38">A2VEC</a>
    <span class="meta">{meta}</span>
  </div>

  <div class="meta">{kicker}</div>
  <h1>{h1}</h1>
  <p class="intro">{intro}</p>
  <div class="links"><a class="primary" href="jetson-jp62.sh" download>{dl}</a><a href="guide.html">{guide}</a><a href="https://github.com/Shippuurl/jetson-jp62">{gh}</a></div>

  <section aria-labelledby="run"><h2 id="run">{s1}</h2><p class="muted">{s1muted}</p>
    <div class="command"><div class="command-head"><span>BASH / jetson-jp62.sh</span><button type="button" id="copy" hidden>{copy}</button></div><pre><code id="command">curl -fL --proto '=https' -o jetson-jp62.sh \\
  https://tool.kervein.club/jetson/jetson-jp62.sh
{ccomment}
bash jetson-jp62.sh --help
bash jetson-jp62.sh</code></pre></div><div id="copy-status" class="status" role="status" aria-live="polite"></div>
    <p class="caution"><strong>{caut_t}</strong><br>{caut_b}</p>
  </section>

  <section aria-labelledby="modes"><h2 id="modes">{s2}</h2><dl class="modes">{modes}</dl><p class="muted">{usage}</p></section>

  <section id="legal"><details><summary>{legal_sum}</summary><h2>{legal_h2}</h2>
    {legal}
    <h2>{mit_h2}</h2><pre>{mit}</pre></details></section>

  <nav class="lang" aria-label="{lang_label}"><span class="meta">{lang_label}</span>{langs}</nav>
  <footer><span>{foot_l}</span><a href="LICENSE">{foot_r}</a></footer>
</section>

<section class="pane right col-wiki" aria-labelledby="prep">
  <div class="pane-top"><span class="meta">{grp_prep}</span></div>
  <h2 id="prep">{prep_h2}</h2>
  <ol class="checklist">{items}</ol>
  <figure><img src="images/jetson-board.jpg" alt="{fig1alt}" width="1100" height="741"><figcaption>{fig1}</figcaption></figure>

  <h3 id="recovery">{rec_h}</h3>
  <p class="muted" style="font-size:13.5px">{rec_intro}</p>
  <div class="method"><p class="method-t"><b>A</b> {rec_a_t}</p><ol class="steps">{rec_a}</ol></div>
  <div class="method"><p class="method-t"><b>B</b> {rec_b_t}</p><ol class="steps">{rec_b}</ol></div>
  <div class="method"><p class="method-t"><b>C</b> {rec_c_t}</p><p class="steps" style="padding-left:0">{rec_c_body} <code>sudo reboot --force forced-recovery</code></p></div>
  <p class="note"><b>{note_t}</b><br><span class="inline-risk">{note_risk}</span><br>{note_seq}</p>
  <div class="gallery">
    <figure><img src="images/jumper-cap.jpg" alt="{fig2alt}" width="1100" height="611"><figcaption>{fig2}</figcaption></figure>
    <figure><img src="images/jumper-cap-installed.jpg" alt="{fig3alt}" width="901" height="575"><figcaption>{fig3}</figcaption></figure>
    <figure><img src="images/lsusb-0955.png" alt="{fig4alt}" width="556" height="93" style="max-width:556px"><figcaption>{fig4}</figcaption></figure>
  </div>
  <p class="caution" style="margin-top:20px">{rec_verify}</p>
  <p class="sources"><span class="meta">{rec_src}</span>{rec_links}</p>

  <h3>{grp_result}</h3>
  <div class="gallery">
    <figure><img src="images/jetpack-version.png" alt="{fig6alt}" width="792" height="426"><figcaption>{fig6}</figcaption></figure>
    <figure><img src="images/flash-done.jpg" alt="{fig5alt}" width="1100" height="957"><figcaption>{fig5}</figcaption></figure>
  </div>
  <p class="muted" style="font-size:12.5px;margin-top:18px">{prep_close}</p>
</section>

</div>
<script>const b=document.getElementById('copy');b.hidden=false;b.addEventListener('click',async()=>{const s=document.getElementById('copy-status');try{await navigator.clipboard.writeText(document.getElementById('command').textContent);s.textContent={copied};}catch{s.textContent={copyfail};}});</script>
</body></html>
"""

COPY = {"zh": ("复制命令", "'已复制。请先审阅脚本。'", "'无法访问剪贴板，请手动复制。'"),
        "en": ("Copy", "'Copied. Review the script first.'", "'Clipboard unavailable; copy manually.'"),
        "ja": ("コピー", "'コピーしました。先にスクリプトを確認してください。'", "'クリップボードを使用できません。手動でコピーしてください。'"),
        "de": ("Kopieren", "'Kopiert. Zuerst das Skript prüfen.'", "'Zwischenablage nicht verfügbar; bitte manuell kopieren.'"),
        "fr": ("Copier", "'Copié. Relisez d’abord le script.'", "'Presse-papiers indisponible ; copiez manuellement.'"),
        "ko": ("복사", "'복사했습니다. 먼저 스크립트를 검토하십시오.'", "'클립보드를 사용할 수 없습니다. 직접 복사하십시오.'")}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def bold(s):
    """**text** -> <span class="danger">text</span>"""
    out, parts = [], s.split("**")
    for i, p in enumerate(parts):
        out.append(f'<span class="danger">{p}</span>' if i % 2 else p)
    return "".join(out)


def build(code):
    t = T[code]
    rec = REC[code]
    alt = "\n".join(
        f'<link rel="alternate" hreflang="{hl}" href="{fn}">' for _, hl, fn, _, _ in LANGS
    ) + '\n<link rel="alternate" hreflang="x-default" href="index.html">'

    langs = "".join(
        f'<span aria-current="true">{label}</span>' if c == code
        else f'<a href="{fn}" hreflang="{hl}" lang="{hl}">{label}</a>'
        for c, hl, fn, label, _ in LANGS
    )

    modes = "".join(
        f"<div><dt>{k}</dt><dd>{bold(v)}</dd></div>" for k, v in t["modes"]
    )
    items = "".join(f"<li><b>{a}</b><span>{b}</span></li>" for a, b in t["items"])
    legal = "".join(f"<p>{p}</p>" for p in t["legal"])
    copy_label, copied, copyfail = COPY[code]

    vals = dict(
        lang=dict((c, hl) for c, hl, _, _, _ in LANGS)[code],
        title=esc(t["title"]), desc=esc(t["desc"]), alt=alt, css=CSS,
        self_href=dict((c, fn) for c, _, fn, _, _ in LANGS)[code],
        meta=t["meta"], kicker=t["kicker"], h1=t["h1"], intro=t["intro"],
        dl=t["dl"], guide=t["guide"], gh=t["gh"],
        s1=t["s1"], s1muted=t["s1muted"], ccomment=t["ccomment"],
        caut_t=t["caut_t"], caut_b=t["caut_b"], s2=t["s2"], modes=modes,
        usage=t["usage"], legal_sum=t["legal_sum"], legal_h2=t["legal_h2"],
        legal=legal, mit_h2=t["mit_h2"], mit=esc(MIT),
        lang_label=t["lang_label"], langs=langs,
        foot_l=t["foot_l"], foot_r=t["foot_r"],
        prep_meta=rec["grp_prep"], prep_h2=t["prep_h2"], items=items,
        note_t=rec["note_t"], note_risk=t["note_risk"], note_seq=rec["note_seq"],
        fig1=t["figs"][0], fig2=t["figs"][1], fig3=t["figs"][2],
        fig1alt=esc(t["figs"][0]), fig2alt=esc(t["figs"][1]), fig3alt=esc(t["figs"][2]),
        prep_close=t["prep_close"],
        grp_prep=rec["grp_prep"], grp_result=rec["grp_result"],
        rec_h=rec["h"], rec_intro=rec["intro"],
        rec_a_t=rec["a_t"], rec_a="".join(f"<li>{x}</li>" for x in rec["a"]),
        rec_b_t=rec["b_t"], rec_b="".join(f"<li>{x}</li>" for x in rec["b"]),
        rec_c_t=rec["c_t"], rec_c_body=rec["c_body"],
        rec_verify=rec["verify"], rec_src=rec["src"],
        rec_links="".join(f'<a href="{u}" rel="noopener">{ti}</a>' for ti, u in SOURCES),
        fig4=rec["fig_lsusb"], fig5=rec["fig_done"], fig6=rec["fig_ver"],
        fig4alt=esc(rec["fig_lsusb"]), fig5alt=esc(rec["fig_done"]), fig6alt=esc(rec["fig_ver"]),
        copy=copy_label,
        copied=copied, copyfail=copyfail,
    )
    html = TPL
    for k in sorted(vals, key=len, reverse=True):   # 用 replace 渲染，避免模板里的 JS { } 干扰
        html = html.replace("{" + k + "}", str(vals[k]))
    out = os.path.join(ROOT, dict((c, fn) for c, _, fn, _, _ in LANGS)[code])
    open(out, "w", encoding="utf-8").write(html)
    return out, len(html)


if __name__ == "__main__":
    for code, *_ in LANGS:
        p, n = build(code)
        print(f"{os.path.basename(p):18} {n:6} bytes")
