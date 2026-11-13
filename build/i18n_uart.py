#!/usr/bin/env python3
"""「串口诊断（UART）」教程文案（6 语）。

依据（页面只做编排与翻译，不改技术事实）：
  1. ProventusNova DeveloperWiki · How to NVIDIA Jetson Orin Nano UART Console
     https://developerwiki.proventusnova.com/How_to_NVIDIA_Jetson_Orin_Nano_UART_Console
     - 40-pin 排针：Pin 8 = UART_TX（接适配器 RXD）、Pin 10 = UART_RX（接适配器 TXD）、GND 共地
     - 波特率 115200；screen /dev/ttyUSB0 115200；minicom 亦可
  2. NVIDIA Developer Forums · How to access UART1 on expansion pins 8/10
     https://forums.developer.nvidia.com/t/how-to-access-uart1-on-expansion-pins-8-10/328934
     - 板内系统侧设备名随版本动态分配（实测 ttyTHS1，非固定 ttyTHS0）
  3. JetsonHacks · Jetson Nano & NX Style - Serial Debug Console
     https://jetsonhacks.com/2019/04/19/jetson-nano-serial-console/
     - 115200 8N1，TX/RX 交叉、GND 共地 的通用接法
"""

SOURCES = [
    ("ProventusNova · How to NVIDIA Jetson Orin Nano UART Console",
     "https://developerwiki.proventusnova.com/How_to_NVIDIA_Jetson_Orin_Nano_UART_Console"),
    ("NVIDIA Developer Forums · UART1 on expansion pins 8/10",
     "https://forums.developer.nvidia.com/t/how-to-access-uart1-on-expansion-pins-8-10/328934"),
    ("JetsonHacks · Serial Debug Console (115200 8N1)",
     "https://jetsonhacks.com/2019/04/19/jetson-nano-serial-console/"),
]

UART = {
"zh": dict(
    h="串口诊断（UART）",
    intro="板子起不来、刷机失败或卡在开机画面时，串口日志能定位问题出现在启动链的哪一层。抓到的是硬件级输出，比 SSH 与 recovery 更接近底层。",
    hw_t="准备",
    hw=["USB-TTL 串口模块（CP2102 / CH340 / FT232 一类，3.3V 电平）", "杜邦线 3 根（母-母）"],
    wire_t="接线（40-pin 排针）",
    wire=["Pin 8 UART_TX → 适配器 RXD", "Pin 10 UART_RX → 适配器 TXD",
          "GND 共地（Pin 6 / 9 / 14 / 25 / 30 / 34 / 39 任一）"],
    par="参数 115200 8N1、无流控。TX 与 RX 必须交叉；接成 TX-TX 会一个字都收不到。",
    run_t="抓取",
    run=["脚本内置：<code>bash jetson-jp62.sh --mode uart</code>（自动找 /dev/ttyUSB*，默认 30 秒）",
         "手工：<code>screen /dev/ttyUSB0 115200</code>（退出 Ctrl-A 再按 K），或 <code>minicom -D /dev/ttyUSB0 -b 115200</code>",
         "先开始抓，再给板子断电 → 上电，才能拿到从 BootROM 到内核的完整启动链"],
    note="板内系统侧设备名是 /dev/ttyTHS1（编号随版本动态分配，不是固定 ttyTHS0）；提示权限不足就把自己加进 dialout 组。",
    lv_t="判读卡在哪一层",
    lv=["BootROM / MB1 / MB2 无输出 → 供电、模组接触、QSPI 固件",
        "停在 UEFI → bootloader 或设备树配置",
        "卡在 kernel → 驱动、根文件系统、存储设备",
        "已到 getty 仍重启 → 应用或 systemd 单元"],
    src="引用",
),
"en": dict(
    h="Serial diagnostics (UART)",
    intro="When the board will not boot, flashing fails, or it hangs at the splash screen, a serial log shows which stage of the boot chain fails. It captures hardware-level output, closer to the metal than SSH or recovery.",
    hw_t="What you need",
    hw=["USB-TTL serial adapter (CP2102 / CH340 / FT232 class, 3.3 V level)", "Three jumper wires (female-female)"],
    wire_t="Wiring (40-pin header)",
    wire=["Pin 8 UART_TX → adapter RXD", "Pin 10 UART_RX → adapter TXD",
          "GND to GND (any of pins 6 / 9 / 14 / 25 / 30 / 34 / 39)"],
    par="115200 8N1, no flow control. TX and RX must cross; wired TX-to-TX you receive nothing at all.",
    run_t="Capturing",
    run=["Built into the script: <code>bash jetson-jp62.sh --mode uart</code> (auto-detects /dev/ttyUSB*, 30 s by default)",
         "Manually: <code>screen /dev/ttyUSB0 115200</code> (exit with Ctrl-A then K), or <code>minicom -D /dev/ttyUSB0 -b 115200</code>",
         "Start capturing first, then power-cycle the board, so you get the whole chain from BootROM to kernel"],
    note="On the board itself the device is /dev/ttyTHS1 (the number is assigned dynamically per release, not always ttyTHS0); add yourself to the dialout group if permission is denied.",
    lv_t="Where it stalls",
    lv=["Nothing from BootROM / MB1 / MB2 → power, module seating, QSPI firmware",
        "Stops in UEFI → bootloader or device-tree configuration",
        "Hangs in kernel → drivers, root filesystem, storage",
        "Reaches getty then reboots → application or systemd unit"],
    src="Sources",
),
"ja": dict(
    h="シリアル診断（UART）",
    intro="起動しない、書き込みに失敗する、起動画面で止まる——こうした症状はシリアルログで起動チェーンのどの段階かを切り分けられます。SSH や recovery より低層の出力が取れます。",
    hw_t="用意するもの",
    hw=["USB-TTL シリアル変換（CP2102 / CH340 / FT232 など、3.3V レベル）", "ジャンパ線 3 本（メス-メス）"],
    wire_t="配線（40 ピンヘッダ）",
    wire=["Pin 8 UART_TX → アダプタの RXD", "Pin 10 UART_RX → アダプタの TXD",
          "GND を共通化（Pin 6 / 9 / 14 / 25 / 30 / 34 / 39 のいずれか）"],
    par="115200 8N1、フロー制御なし。TX と RX は必ず交差させます。TX-TX で繋ぐと 1 文字も受信できません。",
    run_t="取得",
    run=["スクリプト内蔵: <code>bash jetson-jp62.sh --mode uart</code>（/dev/ttyUSB* を自動検出、既定 30 秒）",
         "手動: <code>screen /dev/ttyUSB0 115200</code>（終了は Ctrl-A の後 K）、または <code>minicom -D /dev/ttyUSB0 -b 115200</code>",
         "先に取得を開始し、その後にボードの電源を入れ直すと、BootROM からカーネルまでの全ログが残ります"],
    note="ボード側のデバイス名は /dev/ttyTHS1（番号はリリースごとに動的に割り当てられ、ttyTHS0 固定ではありません）。権限不足なら dialout グループに追加してください。",
    lv_t="どこで止まっているか",
    lv=["BootROM / MB1 / MB2 が出ない → 電源、モジュールの装着、QSPI ファームウェア",
        "UEFI で停止 → bootloader またはデバイスツリー設定",
        "カーネルで停止 → ドライバ、ルートファイルシステム、ストレージ",
        "getty まで到達して再起動 → アプリまたは systemd ユニット"],
    src="参考",
),
"de": dict(
    h="Serielle Diagnose (UART)",
    intro="Wenn das Board nicht startet, das Flashen scheitert oder es beim Startbildschirm hängt, zeigt ein serielles Log, an welcher Stelle der Boot-Kette es endet. Es liefert Ausgaben auf Hardware-Ebene, näher am System als SSH oder Recovery.",
    hw_t="Benötigt",
    hw=["USB-TTL-Serielladapter (CP2102 / CH340 / FT232, 3,3-V-Pegel)", "Drei Jumperkabel (Buchse-Buchse)"],
    wire_t="Verdrahtung (40-Pin-Header)",
    wire=["Pin 8 UART_TX → RXD des Adapters", "Pin 10 UART_RX → TXD des Adapters",
          "GND verbinden (Pin 6 / 9 / 14 / 25 / 30 / 34 / 39)"],
    par="115200 8N1, keine Flusskontrolle. TX und RX müssen gekreuzt werden; TX auf TX ergibt keinerlei Empfang.",
    run_t="Aufzeichnen",
    run=["Im Skript enthalten: <code>bash jetson-jp62.sh --mode uart</code> (/dev/ttyUSB* automatisch, standardmäßig 30 s)",
         "Manuell: <code>screen /dev/ttyUSB0 115200</code> (Beenden mit Ctrl-A, dann K) oder <code>minicom -D /dev/ttyUSB0 -b 115200</code>",
         "Erst die Aufzeichnung starten, dann das Board aus- und wieder einschalten, damit die gesamte Kette von BootROM bis Kernel erfasst wird"],
    note="Auf dem Board selbst heißt das Gerät /dev/ttyTHS1 (die Nummer wird je Release dynamisch vergeben, nicht immer ttyTHS0); bei Berechtigungsfehlern sich in die Gruppe dialout aufnehmen.",
    lv_t="Wo es hängt",
    lv=["Nichts von BootROM / MB1 / MB2 → Stromversorgung, Modulsitz, QSPI-Firmware",
        "Bleibt in UEFI stehen → Bootloader- oder Device-Tree-Konfiguration",
        "Hängt im Kernel → Treiber, Root-Dateisystem, Speicher",
        "Erreicht getty und startet neu → Anwendung oder systemd-Unit"],
    src="Quellen",
),
"fr": dict(
    h="Diagnostic série (UART)",
    intro="Si la carte ne démarre pas, si le flash échoue ou si elle reste bloquée sur l'écran de démarrage, le journal série indique à quelle étape de la chaîne de boot cela se produit. Il donne une sortie au niveau matériel, plus proche du système que SSH ou le recovery.",
    hw_t="Matériel",
    hw=["Adaptateur USB-TTL (CP2102 / CH340 / FT232, niveau 3,3 V)", "Trois fils Dupont (femelle-femelle)"],
    wire_t="Câblage (connecteur 40 broches)",
    wire=["Pin 8 UART_TX → RXD de l'adaptateur", "Pin 10 UART_RX → TXD de l'adaptateur",
          "GND commun (broche 6 / 9 / 14 / 25 / 30 / 34 / 39)"],
    par="115200 8N1, sans contrôle de flux. TX et RX doivent être croisés ; en TX-TX vous ne recevez rien.",
    run_t="Capture",
    run=["Intégré au script : <code>bash jetson-jp62.sh --mode uart</code> (/dev/ttyUSB* détecté automatiquement, 30 s par défaut)",
         "Manuel : <code>screen /dev/ttyUSB0 115200</code> (quitter avec Ctrl-A puis K) ou <code>minicom -D /dev/ttyUSB0 -b 115200</code>",
         "Lancez la capture d'abord, puis coupez et remettez la carte sous tension, pour obtenir toute la chaîne du BootROM au noyau"],
    note="Côté carte, le périphérique est /dev/ttyTHS1 (le numéro est attribué dynamiquement selon la version, pas toujours ttyTHS0) ; en cas de permission refusée, ajoutez-vous au groupe dialout.",
    lv_t="Où cela bloque",
    lv=["Rien depuis BootROM / MB1 / MB2 → alimentation, contact du module, firmware QSPI",
        "Blocage en UEFI → bootloader ou configuration de l'arbre de périphériques",
        "Blocage dans le noyau → pilotes, système de fichiers racine, stockage",
        "Arrive à getty puis redémarre → application ou unité systemd"],
    src="Sources",
),
"ko": dict(
    h="시리얼 진단(UART)",
    intro="보드가 부팅되지 않거나, 플래시가 실패하거나, 부팅 화면에서 멈출 때 시리얼 로그로 부팅 체인의 어느 단계인지 가릴 수 있습니다. SSH나 recovery보다 하드웨어에 가까운 출력을 얻습니다.",
    hw_t="준비물",
    hw=["USB-TTL 시리얼 모듈(CP2102 / CH340 / FT232 계열, 3.3V 레벨)", "점퍼 와이어 3개(암-암)"],
    wire_t="배선(40핀 헤더)",
    wire=["Pin 8 UART_TX → 어댑터 RXD", "Pin 10 UART_RX → 어댑터 TXD",
          "GND 공통(핀 6 / 9 / 14 / 25 / 30 / 34 / 39 중 하나)"],
    par="115200 8N1, 흐름 제어 없음. TX와 RX는 반드시 교차해야 하며, TX-TX로 연결하면 한 글자도 받지 못합니다.",
    run_t="캡처",
    run=["스크립트 내장: <code>bash jetson-jp62.sh --mode uart</code>(/dev/ttyUSB* 자동 탐색, 기본 30초)",
         "수동: <code>screen /dev/ttyUSB0 115200</code>(종료는 Ctrl-A 후 K), 또는 <code>minicom -D /dev/ttyUSB0 -b 115200</code>",
         "먼저 캡처를 시작한 뒤 보드 전원을 껐다 켜야 BootROM부터 커널까지 전체 체인을 얻습니다"],
    note="보드 쪽 장치 이름은 /dev/ttyTHS1입니다(번호는 릴리스마다 동적으로 할당되며 ttyTHS0 고정이 아닙니다). 권한이 거부되면 dialout 그룹에 추가하십시오.",
    lv_t="어디서 멈추는가",
    lv=["BootROM / MB1 / MB2 출력 없음 → 전원, 모듈 접촉, QSPI 펌웨어",
        "UEFI에서 정지 → 부트로더 또는 디바이스 트리 설정",
        "커널에서 멈춤 → 드라이버, 루트 파일 시스템, 저장 장치",
        "getty까지 도달 후 재부팅 → 애플리케이션 또는 systemd 유닛"],
    src="출처",
),
}

# Console output depends on the carrier and BSP configuration.
UART['zh']['intro'] = '独立串口日志采集：连接 USB-TTL、设置串口、保存日志。不需要进入 recovery，也不执行刷写。'
UART['zh']['run'][2] = '先开始采集，再给板子上电。只能采集此 UART 实际输出的日志；40-pin UART 不保证输出早期启动日志。'
UART['zh']['note'] = '主机使用 COMx / /dev/ttyUSBx；板内 ttyTHS 编号和调试控制台端口需按载板及 BSP 核实，不能混用。无输出先查端口、接线、波特率与控制台配置。'
UART['zh']['lv'][0] = '没有启动日志 → 先检查采集端口、接线与控制台配置，不能据此断定固件故障'
UART['en']['intro'] = 'Standalone serial capture: connect USB-TTL, select the port and save logs. No recovery mode or flashing is required.'
UART['en']['run'][2] = 'Start capture before powering on. Only output routed to this UART can be captured; early boot output on the 40-pin UART is not guaranteed.'
UART['en']['note'] = 'Host: COMx / /dev/ttyUSBx. Board-side ttyTHS numbering and the debug console depend on the carrier and BSP. Verify the actual console routing.'
UART['en']['lv'][0] = 'No boot output: check port, wiring and console configuration first; this does not establish a firmware fault'
for lang, intro, run, note in [
 ('ja','独立した UART ログ取得です。recovery や書き込み操作は不要です。','取得を開始してから電源を入れます。この UART に出力されるログのみ取得でき、40 ピン UART で初期起動ログが出る保証はありません。','ホストは COMx / /dev/ttyUSBx を使います。ボード側 ttyTHS とデバッグコンソールはキャリアと BSP に依存します。無出力だけで故障と判断せず、ポートと配線、設定を確認してください。'),
 ('de','Eigenständige UART-Protokollierung, ohne Recovery-Modus oder Flash-Vorgang.','Aufzeichnung vor dem Einschalten starten. Nur auf diesem UART ausgegebene Daten werden erfasst; frühe Boot-Logs am 40-Pin-UART sind nicht garantiert.','Host: COMx / /dev/ttyUSBx. ttyTHS und Debug-Konsole hängen von Trägerplatine und BSP ab. Fehlende Ausgabe beweist keinen Firmwarefehler; Port, Verdrahtung und Konfiguration prüfen.'),
 ('fr','Capture UART indépendante, sans mode recovery ni opération de flash.','Démarrer la capture avant la mise sous tension. Seules les données émises sur cet UART sont capturées ; les journaux de démarrage précoce sur le connecteur 40 broches ne sont pas garantis.','Hôte : COMx / /dev/ttyUSBx. ttyTHS et la console dépendent de la carte porteuse et du BSP. Une absence de sortie ne prouve pas une panne du firmware ; vérifier le port, le câblage et la configuration.'),
 ('ko','recovery 모드나 플래시 작업 없이 독립적으로 UART 로그를 수집합니다.','캡처를 시작한 뒤 전원을 켜십시오. 해당 UART로 출력되는 로그만 수집하며 40핀 UART의 초기 부팅 로그는 보장되지 않습니다.','호스트: COMx / /dev/ttyUSBx. 보드의 ttyTHS 및 디버그 콘솔은 캐리어와 BSP에 따라 다릅니다. 출력이 없다고 펌웨어 고장으로 판단하지 말고 포트, 배선, 설정을 확인하십시오.')]:
    UART[lang]['intro']=intro
    UART[lang]['run'][2]=run
    UART[lang]['note']=note
    UART[lang]['lv'][0]=note
