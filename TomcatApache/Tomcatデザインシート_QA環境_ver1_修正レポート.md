# Tomcatデザインシート（QA環境）ver1 修正レポート

- 作成日：2026/09/17
- 成果物：`sys_renewal\TomcatApache\Tomcatデザインシート_QA環境_ver1.xlsx`
- 元文書：`WebLogicデザインシート_QA環境_ver1.xlsx`（現行 WebLogic 10.3.4 QA 環境の設計書）
- 本書の位置づけ：元文書をどのように Tomcat 用に修正したか（修正箇所・理由）、現行 WebLogic が実現している機能と Tomcat での実現方式、およびご確認いただきたい事項（【要確認】）をまとめたもの。ver1 は「まず 1 版」としての叩き台であり、5 章の回答を反映して ver2 を作成する想定。

---

## 1. 前提と作業方針

### 1.1 前提（ご指示・ヒアリング結果）

| 項目 | 内容 |
|---|---|
| 移行元 | AWS RHEL 5.4／WebLogic Server 10.3.4.0／JRockit 1.6.0_22／Apache HTTP Server 2.2（mod_wl_22）／Oracle 11g |
| 移行先 | AWS RHEL 9／Apache Tomcat 9.0.121／Amazon Corretto 11（OpenJDK 11）／Apache HTTP Server 2.4（mod_proxy_http）／Amazon RDS for Oracle 19c |
| AP／API | 現行の AP サービス・API サービスをともに Tomcat に載せる（1 台の RHEL 9 に Tomcat インスタンス ap01・api01 の 2 本） |
| ログ監視 | Zabbix 7.0 LTS を新規構築し、zabbix-agent2 でログ監視。あわせてプロセス／ポート監視・JMX 監視（Java gateway）・URL／mod_status 監視も Zabbix で実施 |
| Httpd | Apache を継続使用。Listen 80 のみ（TLS は前段 LB／ALB で終端、現行踏襲） |
| 管理コンソール | WLS 管理コンソールの代替として Tomcat Manager を配置（パス・Cookie 名・タイムアウトは現行踏襲） |
| 表記 | 修正箇所は赤字、追加シートは黄タブ、廃止シートは黒タブ（物理削除せず残置） |

### 1.2 修正方針

1. **現行シートに記載のある機能はすべて扱いを決める**（移行／該当なし／廃止）。Tomcat に同等機能がない項目も「該当なし」と理由を明記し、黙って落とさない。
2. **在地修正できるシート**（ユーザ一覧、コンソールログイン、4.JDBC、5.Apache、6.起動スクリプト、7.環境変数、9.チューニング）は元のシート上で赤字修正。値を引き継ぐ項目（現行踏襲）は黒字のまま残し、変更・追加のみ赤字。廃止項目は赤字＋取消線。
3. **WebLogic 固有の構造で大改造が必要なシート**（1.ドメイン、2.管理サーバ、3.管理対象サーバ、8.インストレーション）は黒タブにして参照用に残し、右端に「移行後の扱い（Tomcat）」列（赤字）を追加して全行の移行先を記載。対応する Tomcat 側の設定は黄タブの新規シート（1.共通設定、2.サービス管理、3.インスタンス、8.インストール(Tomcat)）に再構成。
4. **判断が必要な事項は決め打ちしない**：仮置き値を入れたうえで【要確認】を付し、本書 5 章に質問として集約（ブック内の全 【要確認】 は付録 A に一覧）。
5. 元文書の内容・書式（ＭＳ Ｐゴシック 9pt、橙色見出し、黄色＝インスタンス固有値）はそのまま踏襲。追加した書式は「桃色セル＝初期流動時のみ有効化」のみ。

---

## 2. 移行後の構成（ver1 の設計値）

### 2.1 サーバ・インスタンス

| 項目 | 現行（WebLogic） | 移行後（Tomcat） |
|---|---|---|
| ホスト | icapq（AP）／icwaq（API）の 2 台（ドメイン ap_qa_domain／api_qa_domain） | icapq01w 1 台（移行仕様書の構成）に統合 |
| 管理サーバ | icapq-qa-kanri（60100）／icwaq-qa-kanri（60200） | 廃止（機能は systemd・Manager・Zabbix に分担） |
| 管理対象サーバ | ap01・ap02（60111・60112）／api01・api02（60111・60112） | Tomcat インスタンス ap01（60111）・api01（60211）。ap02・api02 は廃止【要確認】 |
| 製品配置 | /opt/oracle/middleware/wlserver_10.3 | CATALINA_HOME=/disk1/tomcat/current → /disk1/tomcat/apache-tomcat-9.0.121 |
| インスタンス | /disk1/weblogic/projects/domains/… | CATALINA_BASE=/disk1/tomcat/instances/ap01・api01 |
| 実行ユーザ | weblogic | tomcat（/sbin/nologin） |
| Java | JRockit 1.6.0_22 | Amazon Corretto 11（/usr/lib/jvm/java-11-amazon-corretto.x86_64） |

### 2.2 ポート設計（ap＝601xx、api＝602xx）

| 用途 | ap01 | api01 | 備考 |
|---|---|---|---|
| Apache | 80 | 80（同一 Apache、名前ベース VirtualHost で振分け） | 現行踏襲 |
| アプリ用 HTTP コネクタ | 60111（127.0.0.1） | 60211（127.0.0.1） | ap01 は現行踏襲。api01 は同一ホストのため採番変更【要確認】 |
| 管理用コネクタ（Manager） | 60100 | 60200 | 現行の管理サーバポートを流用。SG で管理端末に限定 |
| shutdown ポート | 60105 | 60205 | 127.0.0.1 バインド、文字列は推測困難な値 |
| JMX（Zabbix Java gateway） | 60131 | 60231 | ap01 は現行の性能情報取得ポート 60131 を踏襲 |
| Zabbix agent2 | 10050（passive）／10051（active） | 同左 | |

### 2.3 主要コンポーネント

- **Tomcat Manager**（WLS コンソール相当）：`$CATALINA_HOME/webapps/manager` を `$CATALINA_BASE/webapps/web_admin_console` としてコピー配置し、URL を現行と同じ `http://icapq01w…:60100/web_admin_console/`（ap01）に維持。Cookie 名 `WEB_ADM_CONS_SESSION`、セッションタイムアウト 30 分（1800 秒）を踏襲。RemoteAddrValve で管理端末のみ許可し、Apache 側は `ProxyPass "/web_admin_console" "!"` で遮断。ユーザは `tcadmin`（manager-gui, manager-status）【要確認】。
- **Apache 2.4**：mod_wl_22 → mod_proxy_http。`<VirtualHost *:80>` を icapq00w（→ ap01:60111）／icwaq00w（→ api01:60211）で名前ベース振分け。ProxyTimeout 120（WLIOTimeoutSecs 相当）、retry=0（Idempotent OFF 相当）、LogLevel proxy:info（Debug ON 相当、wl_proxy_log は廃止）。MaxClients → MaxRequestWorkers。server-status は Require 構文に変更し Zabbix 用に localhost を許可。
- **JDBC**：WLS データソース gwpx／master／tran → api01 の `context.xml` `<Resource>`（Tomcat JDBC Pool、ojdbc8）。initialSize／maxActive 21、maxWait 10000、validationQuery `SELECT 1 FROM DUAL`、QueryTimeoutInterceptor 30／10／10 秒など現行値を踏襲。接続先は RDS for Oracle 19c（エンドポイント・DB 名【要確認】）。AP 側（ap01）には現行どおり定義しない。
- **JVM／起動**：systemd ユニット tomcat-ap01／tomcat-api01（Type=simple、TimeoutStopSec=150、Restart=no、UMask=0027、StandardOutput=append:catalina.out）＋ `setenv.sh`（-Xms2048m -Xmx2048m、MaxMetaspaceSize 512m【要確認】、G1GC、GC ログ、ヒープダンプ、JMX リモート常時、JFR は初期流動時のみ）。
- **ログ**：juli（catalina.yyyy-mm-dd.log、localhost.yyyy-mm-dd.log）＋catalina.out＋AccessLogValve（access_ap01.log／access_api01.log、pattern common、buffered="false"、rotatable="false"）。Manager のアクセスログ（access_manager_ap01.log）で現行の管理サーバアクセスログを代替。
- **Zabbix**：ログ監視（catalina.out、catalina ログ、localhost ログ、httpd error_log の SEVERE／ERROR／Exception／OutOfMemoryError 等）、プロセス・ポート監視（proc.num、systemd.unit.info、net.tcp.listen）、JMX 監視（ヒープ・GC・スレッドプール・リクエスト統計・セッション・JDBC プール）、URL／mod_status 監視。

---

## 3. 現行 WebLogic が実現している機能と Tomcat での実現方式

現行デザインシートに記載されている機能を機能単位に整理し、Tomcat での実現方式と移行後の設定箇所を示す（ブック内「機能対応表」シートと同内容）。

| No | WebLogic の機能（現行） | 現行の設定箇所 | Tomcat での実現方式（移行後） | 移行後の設定箇所 |
|---|---|---|---|---|
| 1 | ドメイン（ap_qa_domain／api_qa_domain：設定の管理単位） | 1.ドメイン | CATALINA_BASE（/disk1/tomcat/instances/ap01・api01）による設定分離。1 ホストに 2 インスタンス | 1.共通設定 1.1 |
| 2 | 管理サーバ（AdminServer：コンソール・構成配布・起動停止） | 2.管理サーバ | 廃止。設定は各インスタンスの conf ファイル、起動停止は systemd、画面確認は Manager アプリ | 2.サービス管理／コンソールログイン |
| 3 | 管理コンソール（/web_admin_console、60100／60200、Cookie 名・タイムアウト変更） | コンソールログイン、1.ドメイン 1.2 | Tomcat Manager を /web_admin_console として配置。管理用コネクタ 60100／60200、RemoteAddrValve、Cookie 名・タイムアウト踏襲（ap01 の URL は現行と同一） | コンソールログイン、1.共通設定 1.3 |
| 4 | 管理対象サーバ（ap01・ap02／api01・api02：60111・60112） | 3.管理対象サーバ | Tomcat インスタンス ap01（60111）・api01（60211）。ap02・api02 は廃止【要確認】 | 3.インスタンス |
| 5 | 本番モード | 1.ドメイン 1.1 | autoDeploy=false・reloadable=false・development=false・不要アプリ削除 | 1.共通設定 1.2 |
| 6 | HTTP リスニング（ポート・KeepAlive・POST 制限・バックログ） | 3.管理対象サーバ 3.9／3.17 | Connector 属性（port・address・keepAliveTimeout・maxPostSize・acceptCount・connectionUploadTimeout） | 3.インスタンス 3.2、9.チューニング 9.2 |
| 7 | Apache 連携（mod_wl_22：WebLogicCluster・WLIOTimeoutSecs・Idempotent OFF・WLLogFile） | 5.Apache 5.2 | mod_proxy_http：ProxyPass／ProxyPassReverse、ProxyTimeout 120、retry=0、LogLevel proxy:info。名前ベース VirtualHost で ap／api 振分け | 5.Apache 5.2・5.3 |
| 8 | JDBC データソース（gwpx／master／tran：接続プール 21、文タイムアウト 30／10／10） | 4.JDBC | context.xml `<Resource>`（Tomcat JDBC Pool）：initialSize／maxActive 21、maxWait 10000、validationQuery、QueryTimeoutInterceptor。接続先は RDS for Oracle 19c。api01 のみ（現行踏襲） | 4.JDBC |
| 9 | JNDI 名（gwpx 等） | 4.JDBC 4.1 | Resource name を踏襲。ルックアップは java:comp/env/＜name＞【要確認：アプリの resource-ref】 | 4.JDBC 4.1 |
| 10 | JTA（XA・2 フェーズコミット：無効） | 1.ドメイン 1.3・1.4 | 該当なし（ローカルトランザクション。現行も未使用） | 1.共通設定 1.6 |
| 11 | EJB／JMS／JPA／IIOP／jCOM／Web サービス（未使用） | 1.ドメイン、2.管理サーバ、3.管理対象サーバ | 該当なし（Tomcat 非対応・現行も未使用） | 各黒タブシートの「移行後の扱い」列 |
| 12 | セキュリティレルム（myrealm、weblogic ユーザ、ロックアウト、組込み LDAP） | 1.ドメイン 1.10〜1.14、ユーザ一覧 | UserDatabaseRealm（tomcat-users.xml、Manager ユーザ tcadmin）＋LockOutRealm | 1.共通設定 1.9、ユーザ一覧 |
| 13 | セキュリティ対策（コンソールパス・Cookie 名変更、X-Powered-By 非送信、HTTP TRACE 無効、サーバヘッダ非送信） | 1.ドメイン 1.2・1.7、3.管理対象サーバ 3.17 | Manager パス／Cookie 名踏襲、xpoweredBy=false、allowTrace=false、server 未設定、ErrorReportValve、ServerTokens Prod | 1.共通設定 1.3・1.7、3.インスタンス 3.2、5.Apache 5.4 |
| 14 | 構成監査・構成アーカイブ（変更ログ・3 世代） | 1.ドメイン 1.2 | conf ディレクトリの退避（3 世代）・変更記録【要確認：git 等の利用】 | 1.共通設定 1.4 |
| 15 | サーバログ／ドメインログ（ローテーションなし・バッファ 0・日付形式） | 1.ドメイン 1.8・1.9、2／3 ロギング | juli（catalina.yyyy-mm-dd.log、AsyncFileHandler、SimpleFormatter）＋catalina.out【要確認：パージ処理】 | 1.共通設定 1.8、3.インスタンス 3.6 |
| 16 | HTTP アクセスログ（access_ap01.log、共通形式、buffer-size-kb 0、ローテーションなし） | 3.管理対象サーバ 3.23、9.チューニング | AccessLogValve（prefix access_ap01、pattern common、buffered=false、rotatable=false） | 3.インスタンス 3.4、9.チューニング 9.1 |
| 17 | 管理サーバアクセスログ（access_ap-kanri.log） | 2.管理サーバ 2.23、9.チューニング | Manager コンテキストの AccessLogValve（access_manager_ap01.log） | 9.チューニング 9.3 |
| 18 | 起動スクリプト・ヒープ（2048MB、パームヒープ 128／256MB、起動オプション） | 6.起動スクリプト | systemd ユニット＋setenv.sh（-Xms2048m -Xmx2048m、MaxMetaspaceSize 512m、G1GC、GC ログ、ヒープダンプ） | 6.起動スクリプト、2.サービス管理 2.2 |
| 19 | 性能情報取得（JRockit -Xmanagement 60131／60132、診断ボリューム 高） | 6.起動スクリプト、2／3 全般 | JMX リモート（60131／60231、常時、Zabbix Java gateway）＋JFR（初期流動時のみ） | 6.起動スクリプト 7.3・7.4、10.Zabbix監視 10.5 |
| 20 | ヘルス監視・自動再起動なし（180 秒、監視機能に影響する為再起動しない） | 2／3 ヘルス監視 | Zabbix プロセス・ポート・URL・JMX 監視。systemd Restart=no（踏襲） | 10.Zabbix監視、2.サービス管理 2.4 |
| 21 | 正常停止タイムアウト（150 秒） | 2／3 起動停止 | systemd TimeoutStopSec=150 | 2.サービス管理 2.2・2.5 |
| 22 | 起動停止操作（コンソール、wl_mgr_start.sh／wl_mged_start.sh） | コンソールログイン、6.起動スクリプト | systemctl start／stop／status。ジョブからは systemctl を呼び出すスクリプトに改修【要確認：ジョブ起動方式】 | 2.サービス管理 2.5、6.起動スクリプト |
| 23 | デプロイメント（stage モード、ステージング・ディレクトリ） | 2／3 デプロイメント | $CATALINA_BASE/webapps に展開済み WAR を配置 | 2.サービス管理 2.3、3.インスタンス 3.3 |
| 24 | 環境変数（setWLSEnv.sh、ICDB_TOP） | 7.環境変数 | /home/tomcat/.bashrc（JAVA_HOME・CATALINA_HOME・PATH・ICDB_TOP） | 7.環境変数 |
| 25 | インストール（WebLogic インストーラ・JRockit・ドメイン作成ウィザード） | 8.インストレーション | tar.gz 展開＋Corretto 11（dnf）＋conf コピーによるインスタンス作成＋systemd 登録 | 8.インストール(Tomcat) |
| 26 | Apache（httpd.conf：prefork、Listen 80、LogFormat、server-status） | 5.Apache 5.1 | httpd 2.4（RHEL 9）：MaxRequestWorkers、Require 構文、VirtualHost 毎のログ | 5.Apache 5.1・5.3・5.4 |
| 27 | ユーザ（weblogic／OracleSystemUser） | ユーザ一覧 | tcadmin（Manager）、tomcat（OS）、zabbix（OS／JMX）。OracleSystemUser は廃止 | ユーザ一覧 |
| 28 | ログ監視（現行：運用監視製品【要確認】） | － | Zabbix agent2 の log／logrt アイテム（catalina.out・catalina ログ・localhost ログ・httpd error_log）。新規要件 | 10.Zabbix監視 10.3 |
| 29 | SSL（要件なし・LB で終端） | 2／3 キーストア・SSL | 該当なし（Apache 80 のみ、TLS は前段 LB。現行踏襲） | 3.インスタンス 3.2、5.Apache 5.1 |
| 30 | クラスタ（要件なし） | 2／3 クラスタ | 該当なし（現行踏襲） | 3.インスタンス 3.3 |

**Tomcat に同等機能がなく「該当なし」とした主な項目**（いずれも現行で未使用または既定値のまま）：JTA／XA、EJB、JMS、JPA（Kodo）、IIOP、jCOM、Web サービス（信頼できるメッセージ・バッファリング）、T3 トンネリング、Node Manager、組込み LDAP、クロスドメインセキュリティ、ワークコンテキスト伝播、WAP、オーバーロード保護（低メモリ検知）、SSL／キーストア（LB で終端）、クラスタ。

---

## 4. シート別 修正内容

各シートの修正内容を示す（セル単位の明細はブック内「変更明細」シート、件数は「変更一覧」シート参照）。

### 4.1 表紙（新規作成）
- 現行は未復元の空シートだったため、タイトル・版数・対象環境・移行元／移行先・凡例・シート構成・変更履歴を記載。

### 4.2 変更一覧／変更明細／機能対応表（追加・黄タブ）
- 変更一覧：シート別の区分・タブ色・修正概要・修正箇所数・【要確認】件数。
- 変更明細：全修正箇所をシート別・セル／行単位で「変更前 → 変更後」で列挙（在地修正は全セル、黒タブシートは中分類単位、新規シートはセクション単位）。
- 機能対応表：3 章の表。

### 4.3 ユーザ一覧（在地修正）
- 列見出し apサーバ／apiサーバ → ap01／api01。
- weblogic（Administrators）→ **tcadmin【要確認】**（Tomcat Manager ユーザ、ロール manager-gui, manager-status、tomcat-users.xml）。
- OracleSystemUser → 廃止（取消線）。WebLogic 固有の既定ユーザで現行も未使用。
- 追加：tomcat（Tomcat 実行 OS ユーザ）、zabbix（Zabbix agent2 の OS ユーザ。ログ読取のため tomcat グループに追加、/var/log/httpd は ACL）、zabbix（JMX 読取専用ユーザ）。

### 4.4 コンソールログイン（在地修正）
- 「WLS コンソールログイン」→「Tomcat Manager ログイン」。ap01 の URL `http://icapq01w…:60100/web_admin_console/` は現行と同一（黒字のまま）。api01 は `http://icapq01w…:60200/web_admin_console/`（ホスト統合による変更）。
- ユーザ名 weblogic → tcadmin【要確認】。
- 追加：ロール、アクセス許可元（RemoteAddrValve、管理端末 IP【要確認】）、セッションタイムアウト（1800 秒踏襲）、Cookie 名（踏襲）、ロックアウト（LockOutRealm）、主な用途、起動・停止・状態確認（systemctl）、Apache サーバステータス。

### 4.5 1.ドメイン（黒タブ：廃止・参照用）→ 1.共通設定（黄タブ：追加）
- 1.ドメインの全 126 行に「移行後の扱い（Tomcat）」を記載。概要：1.1 全般 → 1.共通設定 1.1（CATALINA_BASE で分離）／1.2 全般(詳細) → Manager・構成管理・JMX／1.3〜1.6 JTA・JPA・EJB → 該当なし／1.7 Web アプリケーション → Connector・web.xml・context.xml 属性（X-Powered-By 非送信、HTTP TRACE 無効、最大 POST サイズ -1、POST タイムアウト 30 秒などを踏襲）／1.8〜1.9 ロギング → logging.properties／1.10〜1.14 セキュリティ → Realm・LockOutRealm・RemoteAddrValve。
- 1.共通設定（66 項目）：1.1 全般（製品・配置）、1.2 本番モード相当、1.3 Manager、1.4 構成管理、1.5 JMX／MBean、1.6 トランザクション／JPA／EJB、1.7 Web アプリケーション共通、1.8 ロギング共通、1.9 セキュリティ。

### 4.6 2.管理サーバ（黒タブ）→ 2.サービス管理（黄タブ）
- 管理サーバは Tomcat に存在しないため廃止。全 233 行に扱いを記載：名前・マシン → 廃止／統合、リスニングポート 60100／60200 → 管理用コネクタに流用、診断ボリューム → JFR・JMX、デプロイメント → webapps、ヘルス監視 → Zabbix、自動再起動なし → Restart=no、ロギング → catalina ログ、HTTP アクセスログ → Manager の AccessLogValve、正常な停止のタイムアウト 150 → TimeoutStopSec=150。SSL・キーストア・クラスタ・JMS・Web サービス・IIOP・jCOM・Node Manager は該当なし。
- 2.サービス管理（40 項目）：2.1 全般（ユニット名・自動起動【要確認】・マシン）、2.2 ユニット設定（[Service] の各項目）、2.3 デプロイメント、2.4 監視、2.5 起動停止。

### 4.7 3.管理対象サーバ（黒タブ）→ 3.インスタンス（黄タブ）
- 全 234 行に扱いを記載：名前 → ap01／api01（ap02・api02 廃止）、リスニングポート → 60111／60211、仮想マシン名 → jvmRoute、チューニング（バックログ 300、KeepAlive 30 秒、POST タイムアウト 30 秒、最大 POST サイズ -1、逆引き DNS なし、サーバヘッダ非送信）→ Connector 属性、ロギング → juli／AccessLogValve、起動停止 → systemd。
- 3.インスタンス（73 項目）：3.1 全般（<Server>）、3.2 HTTP コネクタ（アプリ用・管理用）、3.3 Engine／Host、3.4 Valve（RemoteIpValve・AccessLogValve・ErrorReportValve）、3.5 Context、3.6 ログ、3.7 プロトコル、3.8 チューニング。

### 4.8 4.JDBC（在地修正）
- 見出しを context.xml `<Resource>` 属性に読み替え、設定項目名を「Tomcat 属性名（WLS 項目名）」形式で赤字修正。値は現行踏襲のものを黒字で残置（gwpx／master／tran、oracle.jdbc.OracleDriver、21、21）。
- URL → RDS for Oracle 19c のエンドポイント（【要確認】：エンドポイント・DB 名）。プロパティ user → username、パスワードは現行どおり別紙参照。
- 接続プール（詳細）：予約時テスト → testOnBorrow=false、テスト頻度 120 → timeBetweenEvictionRunsMillis=120000／testWhileIdle=true、テスト表 → validationQuery、信頼秒数 10 → validationInterval=10000、縮小頻度 900 → minEvictableIdleTimeMillis=900000、接続予約タイムアウト 10 → maxWait=10000、文タイムアウト 30／10／10 → QueryTimeoutInterceptor、使用中接続を無視 → removeAbandoned=false。
- 該当なし：増加容量、文キャッシュのタイプ（ドライバ側キャッシュで代替）、システムプロパティ、接続作成の再試行間隔、ログイン遅延、接続の最大待機数、スレッドに固定、影響のある接続の削除、Wrap Data Types、4.4 Oracle 固有設定、4.5 ONS、4.6 トランザクション（XA）、4.7 診断（JMX で代替）、4.8 ID オプション、4.10 セキュリティ・ポリシー。
- 4.9 ターゲット → api01 のみ（現行踏襲）。
- 4.11 追加：type、auth、factory、maxIdle、minIdle、maxAge、jdbcInterceptors、connectionProperties、defaultAutoCommit【要確認】、jmxEnabled、logAbandoned、JDBC ドライバ配置（ojdbc8.jar）。

### 4.9 5.Apache（在地修正）
- 5.1 httpd.conf_for_qa：prefork の MaxClients → MaxRequestWorkers（AP・API 統合による合算値は【要確認】）、ServerName をホスト名に変更（現行 icapq00w／icwaq00w は VirtualHost へ）、api 側の CustomLog／ErrorLog を別ファイル化【要確認】、server-status を 2.4 の Require 構文に変更し Zabbix 用に localhost を許可。Listen 80、Include、ExtendedStatus、LogFormat は現行踏襲（黒字）。
- 5.2 mod_wl_22.conf_for_qa → proxy_tomcat.conf_for_qa：LoadModule（mod_proxy／mod_proxy_http）、共通設定（ProxyRequests Off、ProxyPreserveHost On、ProxyTimeout 120、LogLevel proxy:info）。`<Location />` SetHandler weblogic-handler → VirtualHost 内の ProxyPass。
- 5.3 追加：VirtualHost（ServerName icapq00w／icwaq00w【要確認】）、ProxyPass 除外（/web_admin_console、/server-status）、ProxyPass "/"（60111／60211、retry=0）、ProxyPassReverse、VirtualHost 毎のログ、X-Forwarded-Proto【要確認】。
- 5.4 追加：httpd 版数、ServerTokens／ServerSignature、TraceEnable Off、KeepAlive、Timeout、ログローテーション（logrotate 無効化【要確認】）、SELinux Boolean。

### 4.10 6.起動スクリプト（在地修正）
- 7.1 Apache：起動スクリプトのパスは踏襲、内部を systemctl 呼出しに改修【要確認】。
- 7.2 WebLogic 管理サーバ：廃止（取消線）。
- 7.3 管理対象サーバ → Tomcat インスタンス：起動スクリプト（/disk1/job/tomcat/scripts/tomcat_start.sh【要確認】）、ヒープ 2048／2048 は踏襲（黒字）、パームヒープ → 該当なし、最大パームヒープ 256 → MaxMetaspaceSize 512【要確認】、起動オプション 1（schemaValidation）→ 廃止、起動オプション 2（JRockit -Xmanagement）→ JMX リモート（60131 踏襲／60231、Zabbix 用に常時有効）。
- 7.4 追加：G1GC、GC ログ、ヒープダンプ、JFR（初期流動時のみ・桃色）、システムプロパティ、CATALINA_OPTS、CATALINA_PID。

### 4.11 7.環境変数（在地修正）
- setWLSEnv.sh → JAVA_HOME／CATALINA_HOME／PATH（/home/tomcat/.bashrc）。ICDB_TOP は踏襲（記載先を /home/weblogic → /home/tomcat、参照有無【要確認】）。追加：CATALINA_BASE、LANG／TZ、umask。

### 4.12 8.インストレーション（黒タブ）→ 8.インストール(Tomcat)（黄タブ）
- WebLogic インストーラ・JRockit・ドメイン作成ウィザードの各項目に扱いを記載（Administration Console → Manager、JDBC Drivers → ojdbc8、Web Server Plugins → 不要、Server Examples × → ROOT・docs・examples 削除、ドメイン作成 → インスタンス作成 など）。
- 8.インストール(Tomcat)（49 項目）：Java（Corretto 11）、Tomcat（tar.gz 展開、Manager 配置、不要アプリ削除、ojdbc8、シンボリックリンク）、OS ユーザ・ディレクトリ、インスタンス作成（conf コピー、JMX 認証ファイル、Manager ユーザ、ポート）、systemd 登録、Apache、Zabbix agent2（パッケージ・設定・ログ読取権限）、OS 設定（firewalld・SELinux・logrotate）。

### 4.13 9.チューニング（在地修正）
- config.xml buffer-size-kb 0 → AccessLogValve `buffered="false"`（rotatable="false"、access_ap01.log／access_api01.log を踏襲）。
- 追加：9.2 コネクタ（maxThreads【要確認】、acceptCount 300 踏襲、connectionTimeout、keepAliveTimeout 30 秒踏襲、connectionUploadTimeout 30 秒踏襲）、9.3 Manager アクセスログ（管理サーバアクセスログ相当）、9.4 catalina.out の logrotate【要確認】。

### 4.14 10.Zabbix監視（追加・黄タブ、44 項目）
- 10.1 前提（Zabbix 7.0 LTS 新規、agent2、Java gateway、ポート）、10.2 エージェント設定、10.3 ログ監視（対象ファイル・正規表現・監視間隔・トリガー）、10.4 プロセス・ポート監視、10.5 JMX 監視（エンドポイント、テンプレート、ヒープ・GC・スレッドプール・リクエスト統計・セッション・JDBC プール）、10.6 URL／Apache 監視、10.7 通知・運用。

---

## 5. ご確認いただきたい事項（【要確認】の要点）

ブック内の 【要確認】（付録 A に全件）を論点別にまとめる。各項目には ver1 での仮置き値を記載しているので、「仮置きのままで可」「変更（値）」のいずれかをご指示いただければ ver2 に反映する。

### A. 構成・ポート
1. **インスタンス数**：現行の ap01・ap02／api01・api02（各 2 本）を ap01／api01（各 1 本）に集約している。1 本ずつでよいか（冗長化・性能要件）。［3.インスタンス 3.1］
2. **api01 のアプリ用ポート**：同一ホスト化に伴い 60111 → 60211 に採番変更。ap＝601xx／api＝602xx の採番規則でよいか。［3.インスタンス 3.2、5.Apache 5.3］
3. **管理用コネクタ**：Manager 用に 60100／60200（現行管理サーバのポート）を流用。同ポートでアプリにも到達できるため、セキュリティグループで管理端末セグメントに限定する前提でよいか。代替案：管理用コネクタを設けず SSH ポートフォワード経由（127.0.0.1 バインド）とする。［1.共通設定 1.3、3.インスタンス 3.2］
4. **JMX ポート**：ap01 は現行 60131 を踏襲、api01 は 60231。Zabbix Java gateway から到達できるよう全アドレスにバインド（SSL なし、パスワード認証）でよいか。［1.共通設定 1.5、6.起動スクリプト 7.3］
5. **Apache の VirtualHost 振分け**：LB からの Host ヘッダが icapq00w／icwaq00w（現行 ServerName）のまま届く前提で名前ベース VirtualHost としている。LB 側の設定（Host ヘッダの扱い、DNS 名）をご教示ください。［5.Apache 5.1・5.3］
6. **X-Forwarded-Proto**：前段 LB が TLS 終端する場合、LB が付与するヘッダ名（X-Forwarded-Proto 等）。［5.Apache 5.3、3.インスタンス 3.4］

### B. Manager（管理コンソール）
7. **Manager ユーザ名**：仮置き `tcadmin`（ロール manager-gui, manager-status）。［ユーザ一覧、コンソールログイン］
8. **アクセス許可元 IP**：現行 server-status の許可元 202.221.112.146 を管理端末として仮置き。Manager を許可する端末・セグメントをご教示ください。［コンソールログイン、1.共通設定 1.3］

### C. Apache
9. **MaxRequestWorkers**：1 台で AP（現行 256）と API（現行 42）を処理するため、256 のままか合算（298）か。性能測定で確定する前提でよいか。［5.Apache 5.1］
10. **api 側のログファイル名**：VirtualHost 毎に分離し `access_log_api_for_qa`／`error_log_api_for_qa` と仮置き。命名規則の指定があればご教示ください。［5.Apache 5.1・5.3］
11. **設定ファイルの `_for_qa` 命名**：現行の httpd.conf_for_qa／conf.d/*.conf_for_qa の運用（httpd.service の -f 指定など）を RHEL 9 でも踏襲するか。［8.インストール(Tomcat)］
12. **Apache の logrotate**：RHEL 標準の週次 logrotate を無効化して現行「ファイルパージ処理」を踏襲するか。［5.Apache 5.4］

### D. JDBC・アプリケーション
13. **RDS エンドポイント・DB 名（サービス名）**：処理用DB（disp）・統合顧客DB（main）を RDS 1 インスタンスに統合する前提で、3 データソースとも同一 DB 名としている。確定後にご連絡ください。［4.JDBC 4.2］
14. **JNDI ルックアップ名**：Tomcat では `java:comp/env/gwpx` となるため、アプリ（Spring の jndi-lookup／web.xml の resource-ref）の記述を確認したい。［4.JDBC 4.1］
15. **AP 側（ap01）のデータソース**：現行どおり定義なしとしている。AP アプリが JDBC を使用していないことを確認したい。［4.JDBC 4.9、3.インスタンス 3.5］
16. **defaultAutoCommit／トランザクションタイムアウト**：アプリ（Spring）側のトランザクション制御方式（現行 WLS JTA タイムアウト 30 秒の扱い）。［4.JDBC 4.11、1.共通設定 1.6］
17. **oracle.jdbc.ReadTimeout**：接続タイムアウト（CONNECT_TIMEOUT 10 秒）に加え、読取タイムアウトを設定するか。［4.JDBC 4.11］
18. **コンテキストパス・セッション Cookie**：現行 AP／API アプリのコンテキストルート、weblogic.xml の cookie-name・session-timeout の値。［2.サービス管理 2.3、1.共通設定 1.7］
19. **URL 文字**：Tomcat 9 は RFC 7230 違反文字（`|`、`{` 等）を 400 応答するため、アプリの URL で使用していないか（relaxedQueryChars 要否）。［3.インスタンス 3.2］

### E. JVM・起動・運用
20. **MaxMetaspaceSize**：現行の最大パームヒープ 256MB に対し 512MB を仮置き。［6.起動スクリプト 7.3］
21. **maxThreads**：200（Tomcat 既定）を仮置きし性能測定で確定。［3.インスタンス 3.2、9.チューニング 9.2］
22. **起動方式**：systemd の自動起動（enable）を有効にするか、現行どおりジョブ（JP1 等）から起動スクリプトで起動するか。起動スクリプトの配置先（仮置き /disk1/job/tomcat/scripts）。［2.サービス管理 2.1、6.起動スクリプト］
23. **現行起動スクリプトの -D 指定**：wl_mged_start.sh 内で指定しているシステムプロパティ（file.encoding、timezone 等）の有無。［6.起動スクリプト 7.4］
24. **ICDB_TOP**：/disk1/hyojun/build をアプリ・ジョブが参照しているか（/home/tomcat/.bashrc への移設で足りるか）。［7.環境変数］
25. **構成監査・アーカイブ**：conf の変更記録を作業記録で管理する仮置き。git 等の構成管理ツールを使うか。［1.共通設定 1.4］

### F. ログ・パージ
26. **ログローテーションとパージ処理**：現行「ローテーションなし＋ファイルパージ処理」に対し、Tomcat は juli が日次ローテーション（catalina.yyyy-mm-dd.log）する。パージ処理の改修方針（日付付きファイルの削除）、catalina.out の logrotate 要否。［1.共通設定 1.8、3.インスタンス 3.6、9.チューニング 9.4］
27. **ログの日付形式**：現行「yyyy/MM/dd H時mm分ss秒 z」相当の SimpleFormatter 形式を仮置き。運用監視・ログ解析で形式の指定があればご教示ください。［1.共通設定 1.8］
28. **StuckThreadDetectionValve**：現行「スタックスレッド最大時間 600 秒」相当の検知を Tomcat でも行うか（仮置き：使用しない）。［3.インスタンス 3.4］

### G. Zabbix
29. **Zabbix サーバ**：IP アドレス、Java gateway の配置先（サーバ同居想定）。［10.Zabbix監視 10.1］
30. **ログ監視の対象・キーワード**：仮置き（SEVERE／ERROR／Exception／OutOfMemoryError／StackOverflowError、httpd は [module:error] 以上）。アプリケーションログ（log4j 等）の出力先・監視キーワード・除外パターン、現行の運用監視で監視している内容をご教示ください。［10.Zabbix監視 10.3］
31. **監視間隔・閾値・通知**：ログ監視 30 秒、ヒープ 90%（5 分）、スレッド busy 80%、通知先、重要度ルール。［10.Zabbix監視 10.3・10.5・10.7］
32. **Zabbix ホストの分割**：JMX 監視のためインスタンス毎にホスト（icapq01w-ap01／icapq01w-api01）を分ける想定。［10.Zabbix監視 10.5］
33. **HTTP 死活の URL**：Apache 経由で Tomcat まで到達確認する URL と期待応答。［10.Zabbix監視 10.6］
34. **OS 監視項目**：基盤設計書側の Zabbix 監視項目との整合。［10.Zabbix監視 10.4］

### H. OS・インストール
35. **Java パッケージ**：Amazon Corretto 11 を仮置き（RHEL 標準 java-11-openjdk とする場合は JAVA_HOME を読み替え）。［8.インストール(Tomcat)］
36. **OS ユーザ tomcat／zabbix の uid・gid**：基盤設計書の OS 設定との整合。［ユーザ一覧、8.インストール(Tomcat)］
37. **SELinux**：enforcing 運用の可否（httpd_can_network_connect=on、/disk1/tomcat のコンテキスト）。［1.共通設定 1.9、8.インストール(Tomcat)］
38. **JMX SSL**：VPC 内閉域のため SSL なし（パスワード認証のみ）でよいか。［1.共通設定 1.5］

---

## 6. 現行シートについて気づいた点（修正していない事項）

- 4.JDBC の列見出し G3 が「main」だが、データソース名（G6・G7）は「tran」。現行シートのままとしたが、ver2 で「tran」に直すか確認したい。
- 7.環境変数 C4 の「（空行）」は動画復元時の注記のため、削除してよいと思われる。
- 6.起動スクリプトの大分類が「7.起動スクリプト」、9.チューニングの中分類が「9.WebLogic」など、シート名と番号がずれている箇所は現行踏襲（番号は変更していない）。
- 現行 2.管理サーバ／3.管理対象サーバの「診断ボリューム 高」「アクセスログのバッファ 0」など赤字（初期流動時のみ・性能チーム要件）の注記は、黒タブシートではそのまま残している。新規シートでは「桃色セル」で表現した。

---

## 7. 次版（ver2）に向けて

1. 5 章の回答を反映（仮置き値の確定・【要確認】の解消）。
2. コンテキストパス・JNDI 名・アプリ設定（web.xml／weblogic.xml）の確認結果を 2.サービス管理・4.JDBC に反映。
3. Zabbix 側（テンプレート・トリガー・通知）の詳細設計を 10.Zabbix監視 に追記。
4. 本番（honban）・開発（dev）環境向けは、QA 版確定後にホスト名・エンドポイント・IP を置き換えて作成。
5. 確定した設定値から server.xml／context.xml／setenv.sh／systemd ユニット／proxy_tomcat.conf／zabbix_agent2.conf の設定ファイル雛形を作成（移行設計書 付録 B を更新）。


---

## 付録 A. 【要確認】一覧（ブック内の全件、シート順：98 件）

| No | シート | セル | 項目 | 内容（仮置き値・確認事項） |
|---|---|---|---|---|
| 1 | 機能対応表 | F7 | 管理対象サーバ（ap01・ap02／api01・api02：60111・60112） | 【要確認】1 インスタンス構成 |
| 2 | 機能対応表 | F12 | JNDI 名（gwpx 等） | 【要確認】アプリの resource-ref |
| 3 | 機能対応表 | F17 | 構成監査・構成アーカイブ（変更ログ・3 世代） | 【要確認】git 等の利用 |
| 4 | 機能対応表 | F18 | サーバログ／ドメインログ（ローテーションなし・バッファ 0・日付形式） | 【要確認】パージ処理 |
| 5 | 機能対応表 | F25 | 起動停止操作（コンソール、wl_mgr_start.sh／wl_mged_start.sh） | 【要確認】ジョブ起動方式 |
| 6 | 機能対応表 | B31 |  | ログ監視（現行：運用監視製品【要確認】） |
| 7 | ユーザ一覧 | A4 |  | tcadmin【要確認】 |
| 8 | ユーザ一覧 | F4 | tcadmin【要確認】 | Tomcat Manager（WLS 管理コンソール相当）のログインユーザ。$CATALINA_BASE/conf/tomcat-users.xml にインスタンス毎に定義 ※パスワードに関しては、ユーザパスワード一覧.xls参照 （現行 weblogic／Administrators を置換。ユーザ名は【要確認】） |
| 9 | ユーザ一覧 | F6 | tomcat | Tomcat 実行ユーザ（OS ユーザ。systemd の User=／Group=）。ログインシェル /sbin/nologin、uid／gid は OS 設計に従う【要確認】 ログインパスワードなし（運用者は sudo で操作）。現行 weblogic OS ユーザ（/home/weblogic）相当 |
| 10 | ユーザ一覧 | F8 | zabbix（JMX） | Zabbix Java gateway からの JMX 接続用ユーザ（$CATALINA_BASE/conf/jmxremote.password）。読取専用。ユーザ名は【要確認】 ※パスワードに関しては、ユーザパスワード一覧.xls参照 |
| 11 | コンソールログイン | D6 | ユーザ名 | tcadmin【要確認】 |
| 12 | コンソールログイン | D8 | アクセス許可元 | RemoteAddrValve allow="127\.0\.0\.1｜202\.221\.112\.146"【要確認】（管理端末 IP） |
| 13 | 1.ドメイン | H20 | 構成監査のタイプ | → 1.共通設定 1.4：$CATALINA_BASE/conf の変更記録【要確認】（方式） |
| 14 | 1.ドメイン | H83 | ローテーションタイプ | juli は日次ローテーション（catalina.yyyy-mm-dd.log）。パージは現行パージ処理を流用【要確認】 |
| 15 | 1.ドメイン | H92 | 日付フォーマットパターン | logging.properties の java.util.logging.SimpleFormatter.format（yyyy/MM/dd HH:mm:ss 形式）【要確認】 |
| 16 | 1.共通設定 | E26 | アクセス制御 | RemoteAddrValve allow="127\.0\.0\.1｜202\.221\.112\.146"【要確認】（管理端末 IP） |
| 17 | 1.共通設定 | H27 | 管理用コネクタ | Manager 専用の HTTP コネクタ（3.インスタンス 3.2）。現行 WLS 管理サーバのポート番号を流用。セキュリティグループで管理端末セグメントのみ許可【要確認】 |
| 18 | 1.共通設定 | H28 | ユーザ／ロール | ユーザ一覧 参照【要確認】（ユーザ名） |
| 19 | 1.共通設定 | E33 | 構成監査（変更ログ） | 変更作業記録（作業手順書・変更管理票）で管理【要確認】（git 等の構成管理ツール利用） |
| 20 | 1.共通設定 | H40 | JMX SSL | VPC 内の閉域通信の為 SSL なし【要確認】 |
| 21 | 1.共通設定 | E43 | トランザクションタイムアウト | アプリ側（Spring）で制御【要確認】 |
| 22 | 1.共通設定 | H54 | セッション Cookie | 現行 WLS も JSESSIONID【要確認】（weblogic.xml の cookie-name） |
| 23 | 1.共通設定 | E55 | セッションタイムアウト（アプリ） | アプリの web.xml に従う【要確認】 |
| 24 | 1.共通設定 | H66 | ローテーション | 現行「ローテーションタイプなし（ファイルパージ処理にて実施）」。日付付きファイルのパージは現行パージ処理を改修【要確認】 |
| 25 | 1.共通設定 | H68 | 日付フォーマット | 現行「yyyy/MM/dd H時mm分ss秒 z」相当【要確認】（Zabbix ログ監視の正規表現と整合） |
| 26 | 1.共通設定 | E78 | SELinux／firewalld | enforcing／許可ポート：80、60100・60200（管理端末）、60131・60231（Zabbix JMX）、10050（Zabbix agent）【要確認】 |
| 27 | 2.管理サーバ | I26 | 起動モード | systemctl enable（OS 起動時に自動起動）【要確認】→ 2.サービス管理 2.1 |
| 28 | 2.管理サーバ | I106 | ヘルスチェック間隔 | Zabbix 監視間隔【要確認】 |
| 29 | 2.管理サーバ | I187 | ローテーションタイプ | juli 日次ローテーション【要確認】（パージ処理） |
| 30 | 2.サービス管理 | E9 | 自動起動（systemctl enable） | 有効【要確認】（ジョブ（JP1）起動とする場合は無効） |
| 31 | 2.サービス管理 | H31 | デプロイ方式 | WLS stage モード相当。Manager からの WAR アップロードは行わない【要確認】（リリース手順） |
| 32 | 2.サービス管理 | E33 | コンテキストパス | ＜現行 AP アプリのコンテキストルート＞【要確認】 |
| 33 | 2.サービス管理 | F33 | コンテキストパス | ＜現行 API アプリのコンテキストルート＞【要確認】 |
| 34 | 3.管理対象サーバ | K26 | 起動モード | systemctl enable【要確認】 |
| 35 | 3.管理対象サーバ | K82 | スタックスレッド最大時間 | StuckThreadDetectionValve（使用しない【要確認】） |
| 36 | 3.管理対象サーバ | K107 | ヘルスチェック間隔 | Zabbix 監視間隔【要確認】 |
| 37 | 3.管理対象サーバ | K146 | 最大メッセージサイズ | maxSwallowSize／Apache LimitRequestBody【要確認】 |
| 38 | 3.管理対象サーバ | K188 | ローテーションタイプ | juli 日次ローテーション【要確認】（パージ処理） |
| 39 | 3.インスタンス | H6 | 名前（インスタンス名） | WLS icapq-qa-ap01／icwaq-qa-api01 相当（ap02・api02 は廃止：各 1 インスタンス）【要確認】 |
| 40 | 3.インスタンス | H17 | アプリ用コネクタ port | ap01 は現行 60111 踏襲。api01 は同一ホストの為 60211 に採番【要確認】 |
| 41 | 3.インスタンス | H19 | 管理用コネクタ port（Manager 用） | 現行 WLS 管理サーバのポート番号を流用。Manager アプリ専用（RemoteAddrValve＋SG で管理端末に限定）【要確認】（アプリもこのポートで応答する為 SG 制限必須） |
| 42 | 3.インスタンス | E24 | maxThreads | 200【要確認】 |
| 43 | 3.インスタンス | E41 | relaxedQueryChars／relaxedPathChars | 未設定【要確認】（アプリの URL 文字） |
| 44 | 3.インスタンス | E58 | StuckThreadDetectionValve | 使用しない【要確認】 |
| 45 | 3.インスタンス | H62 | Resource（JNDI データソース） | 現行どおり API 側のみ接続プールを使用（AP は JDBC アクセス要件なし【要確認】） |
| 46 | 3.インスタンス | H73 | ローテーション | 現行「ファイルパージ処理にて実施する為、不要」踏襲【要確認】（パージ処理の改修） |
| 47 | 3.インスタンス | E79 | 最大メッセージサイズ | maxSwallowSize／maxPostSize（3.2）、Apache LimitRequestBody【要確認】 |
| 48 | 3.インスタンス | E85 | スレッド数・ヒープの確定 | 性能測定（初期流動）で確定【要確認】 |
| 49 | 4.JDBC | I7 | JNDI 名（アプリからのルックアップ名） | 現行は JNDI 名 "gwpx" 等で直接ルックアップ。Tomcat では java:comp/env/ 配下となる為、アプリの JNDI ルックアップ名（Spring の jndi-lookup）又は web.xml の resource-ref を確認【要確認】 |
| 50 | 4.JDBC | E12 | url | jdbc:oracle:thin:@//icdbq01.＜アカウント固有ID＞.ap-northeast-1.rds.amazonaws.com:1521/＜DB名（サービス名）＞【要確認】 |
| 51 | 4.JDBC | I12 | url | Oracle 11g（現行 icdbq01d、ポート 50001／50000）→ Amazon RDS for Oracle 19c（icdbq01、1521）。RDS は 1 インスタンス（処理用DB（disp）・統合顧客DB（main）を同一 DB 内のスキーマとして統合予定）の為、DB 名（サービス名）・エンドポイントは RDS 構築後に確定【要確認】 |
| 52 | 4.JDBC | I68 | サーバー | 現行どおり API サーバのみ（Icwaq-api01／api02 → api01 の $CATALINA_BASE/conf/context.xml に定義）。AP サーバについては、構築時にアプリケーションの JDBC アクセス要件が無い為 ap01 には定義しない【要確認】 |
| 53 | 4.JDBC | I82 | connectionProperties | 文キャッシュ（21 行目）＋接続タイムアウト 10 秒【要確認】（oracle.jdbc.ReadTimeout の要否） |
| 54 | 4.JDBC | I83 | defaultAutoCommit | 【要確認】アプリ（Spring）のトランザクション制御方式 |
| 55 | 5.Apache | F6 | <IfModule mpm_prefork_module> | 同左（同一 Apache で AP・API を処理する為、合算値の要否を要検討）【要確認】 |
| 56 | 5.Apache | E10 | ServerName | icapq01w.ydc.fujixerox.co.jp:80【要確認】 |
| 57 | 5.Apache | F12 | CustomLog | logs/access_log_api_for_qa combined【要確認】 |
| 58 | 5.Apache | F13 | ErrorLog | logs/error_log_api_for_qa【要確認】 |
| 59 | 5.Apache | H14 | <Location /server-status> | サーバーステータス画面表示 新規追加項目 ※性能チーム要件 2.4 の Require 構文に変更（Order/Deny/Allow は廃止）。Zabbix の Apache 監視（10.Zabbix監視 10.6）用に localhost を許可【要確認】 |
| 60 | 5.Apache | E20 | <VirtualHost *:80> | icapq00w.ydc.fujixerox.co.jp【要確認】（LB からの Host ヘッダ） |
| 61 | 5.Apache | F20 | <VirtualHost *:80> | icwaq00w.ydc.fujixerox.co.jp【要確認】 |
| 62 | 5.Apache | F24 | CustomLog／ErrorLog | logs/access_log_api_for_qa combined／logs/error_log_api_for_qa【要確認】 |
| 63 | 5.Apache | E25 | RequestHeader（X-Forwarded-Proto） | RequestHeader set X-Forwarded-Proto "https"【要確認】（前段 LB が付与するヘッダ） |
| 64 | 5.Apache | E32 | ログローテーション | logrotate（/etc/logrotate.d/httpd）は無効化し、現行「ファイルパージ処理」を踏襲【要確認】 |
| 65 | 6.起動スクリプト | H5 | 起動スクリプト | スクリプト内部を systemctl start httpd の呼出しに改修【要確認】（ジョブ（JP1）からの起動方式） |
| 66 | 6.起動スクリプト | E14 | 起動スクリプト | /disk1/job/tomcat/scripts/tomcat_start.sh【要確認】 （内部で systemctl start tomcat-ap01 を実行） |
| 67 | 6.起動スクリプト | E18 | 最大 Metaspace サイズ(MB)（-XX:MaxMetaspaceSize：最大パームヒープ相当） | 512【要確認】 |
| 68 | 6.起動スクリプト | E20 | 起動オプション2（性能情報取得：JMX リモート） | -Dcom.sun.management.jmxremote.port=60131 -Dcom.sun.management.jmxremote.rmi.port=60131 -Dcom.sun.management.jmxremote.authenticate=true -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.password.file=$CATALINA_BASE/conf/jmxremote.password -Dcom.sun.management.jmxremote.access.file=$CATALINA_BASE/conf/jmxremote.access -Djava.rmi.server.hostname=＜本サーバ IP＞【要確認】 |
| 69 | 6.起動スクリプト | F20 | 起動オプション2（性能情報取得：JMX リモート） | -Dcom.sun.management.jmxremote.port=60231 -Dcom.sun.management.jmxremote.rmi.port=60231 -Dcom.sun.management.jmxremote.authenticate=true -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.password.file=$CATALINA_BASE/conf/jmxremote.password -Dcom.sun.management.jmxremote.access.file=$CATALINA_BASE/conf/jmxremote.access -Djava.rmi.server.hostname=＜本サーバ IP＞【要確認】 |
| 70 | 6.起動スクリプト | H26 | システムプロパティ | 文字コード・タイムゾーン・乱数生成（起動遅延防止）【要確認】（現行起動スクリプトの -D 指定を確認） |
| 71 | 7.環境変数 | F6 | ICDB_TOP | 構成管理要件 /home/tomcat/.bashrcに記載（現行 /home/weblogic/.bashrc から移設）【要確認】（アプリ・ジョブでの参照有無） |
| 72 | 7.環境変数 | F7 | CATALINA_BASE | 手動で catalina.sh を実行する際に対象インスタンスを指定（.bashrc には既定として ap01 を記載）【要確認】 |
| 73 | 8.インストレーション | J30 | 名前 | Manager ユーザ tcadmin【要確認】（tomcat-users.xml） |
| 74 | 8.インストール(Tomcat) | I4 | パッケージ | RHEL 標準 java-11-openjdk を採用する場合は JAVA_HOME を読み替え【要確認】 |
| 75 | 8.インストール(Tomcat) | F20 | ユーザ／グループ | tomcat／tomcat（/sbin/nologin、uid・gid は OS 設計【要確認】） |
| 76 | 8.インストール(Tomcat) | F22 | ジョブ・スクリプト | /disk1/job/tomcat/scripts【要確認】 |
| 77 | 8.インストール(Tomcat) | F30 | Manager ユーザ | tcadmin【要確認】（tomcat-users.xml、manager-gui,manager-status） |
| 78 | 8.インストール(Tomcat) | I44 | daemon-reload／enable | 自動起動の要否は【要確認】（2.サービス管理 2.1） |
| 79 | 8.インストール(Tomcat) | F48 | 設定ファイル | /etc/httpd/conf/httpd.conf_for_qa、/etc/httpd/conf.d/proxy_tomcat.conf_for_qa【要確認】（_for_qa 命名の踏襲方法） |
| 80 | 8.インストール(Tomcat) | I57 | Boolean | Apache → Tomcat（localhost:60111／60211）の接続許可【要確認】（enforcing 運用） |
| 81 | 8.インストール(Tomcat) | F58 | コンテキスト | /disk1/tomcat 配下：既定（unconfined 実行）【要確認】 |
| 82 | 8.インストール(Tomcat) | F59 | 対象 | catalina.out（/etc/logrotate.d/tomcat）【要確認】（現行パージ処理との整合） |
| 83 | 9.チューニング | E8 | maxThreads | 200【要確認】 |
| 84 | 9.チューニング | E17 | catalina.out | /etc/logrotate.d/tomcat：weekly、rotate 4、copytruncate、compress【要確認】 |
| 85 | 10.Zabbix監視 | E6 | Zabbix サーバ | Zabbix 7.0 LTS（新規構築）、IP＝＜Zabbix サーバ IP＞【要確認】 |
| 86 | 10.Zabbix監視 | H8 | Java gateway | JMX 監視用。Java gateway → 本サーバ 60131／60231【要確認】（配置先） |
| 87 | 10.Zabbix監視 | H20 | 対象 1：catalina.out | 標準出力・標準エラー（アプリの例外スタックトレース含む）。検知キーワードは【要確認】 |
| 88 | 10.Zabbix監視 | E24 | 対象 5：アプリケーションログ | ＜アプリ（log4j 等）の出力先＞【要確認】（対象・キーワード） |
| 89 | 10.Zabbix監視 | E25 | 監視間隔（Update interval） | 30s【要確認】 |
| 90 | 10.Zabbix監視 | E26 | 除外パターン | 必要に応じて設定（例：INFO 行に含まれる "Exception" 文字列）【要確認】 |
| 91 | 10.Zabbix監視 | H36 | OS 監視 | 基盤設計書の監視項目と整合【要確認】 |
| 92 | 10.Zabbix監視 | H39 | テンプレート | インスタンス毎に Zabbix ホスト（icapq01w-ap01／icapq01w-api01）を作成【要確認】（ホスト分割方式） |
| 93 | 10.Zabbix監視 | H40 | ヒープ使用量 | 使用率 90% 超（5 分継続）でトリガー【要確認】（閾値） |
| 94 | 10.Zabbix監視 | H42 | スレッドプール | busy 率 80% 超でトリガー【要確認】 |
| 95 | 10.Zabbix監視 | H44 | セッション数 | 【要確認】（コンテキストパス） |
| 96 | 10.Zabbix監視 | H49 | HTTP 死活（Apache → Tomcat） | Apache 経由で Tomcat まで到達することを確認（VirtualHost 振分けの為 Host ヘッダを指定）。URL・期待応答は【要確認】 |
| 97 | 10.Zabbix監視 | E52 | 通知先 | 【要確認】（メール／チャット等） |
| 98 | 10.Zabbix監視 | H53 | 重要度の目安 | 【要確認】（運用ルール） |

## 付録 B. シート別 修正記録数（「変更明細」シートの件数）

| シート | 件数 | 内訳 |
|---|---|---|
| 表紙 | 1 | 新規作成:1 |
| 機能対応表 | 1 | 新規シート:1 |
| ユーザ一覧 | 12 | 変更:5、廃止:4、追加:3 |
| コンソールログイン | 15 | 変更:7、追加:8 |
| 1.ドメイン | 16 | 廃止シート:1、移行先:15 |
| 1.共通設定 | 11 | 新規:10、新規シート:1 |
| 2.管理サーバ | 27 | 廃止シート:1、移行先:26 |
| 2.サービス管理 | 7 | 新規:6、新規シート:1 |
| 3.管理対象サーバ | 27 | 廃止シート:1、移行先:26 |
| 3.インスタンス | 10 | 新規:9、新規シート:1 |
| 4.JDBC | 247 | 変更:233、追加:13、追記:1 |
| 5.Apache | 44 | 変更:18、追加:15、追記:11 |
| 6.起動スクリプト | 43 | 変更:23、廃止:9、追加:8、追記:3 |
| 7.環境変数 | 9 | 変更:6、追加:3 |
| 8.インストレーション | 4 | 廃止シート:1、移行先:3 |
| 8.インストール(Tomcat) | 9 | 新規:8、新規シート:1 |
| 9.チューニング | 20 | 変更:9、追加:11 |
| 10.Zabbix監視 | 9 | 新規:8、新規シート:1 |
| 合計 | 512 | |

※ 区分：変更＝既存セルの値を赤字で変更／追加＝行・セクションの追加／追記＝既存の備考（黒字）に赤字注記を追記／廃止＝赤字取消線／移行先＝黒タブシートの中分類毎の移行先／新規＝新規シートのセクション
