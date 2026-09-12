# WebLogic 現行環境調査手順書

**処理用DB老朽化対応 — WebLogic Server 10.3.4.0 → Apache HTTP Server + Tomcat 9 移行**

| 項目 | 内容 |
|---|---|
| 文書名 | WebLogic 現行環境調査手順書 |
| 版 | ver1 |
| 作成日 | 2026-09-12 |
| 対象 | 現行 WebLogic Server 10.3.4.0（AWS RHEL 5.4）上で稼働する Java EE Web アプリケーション（Spring MVC 3 / JNDI 経由 Oracle 接続） |
| 用途 | Tomcat 9 + Apache への移行設計（設計書）のインプットとなる現行調査の実施手順 |

## 改訂履歴

| 版 | 日付 | 変更内容 | 作成者 |
|---|---|---|---|
| ver1 | 2026-09-12 | 初版作成（調査項目・調査方法・確認方法・記録様式・付録） | — |

---

## 目次

1. [本書の目的と位置づけ](#1-本書の目的と位置づけ)
2. [調査の進め方（全体方針）](#2-調査の進め方全体方針)
3. [調査項目一覧（マトリクス）](#3-調査項目一覧マトリクス)
4. [調査項目の詳細（目的・調査方法・確認方法）](#4-調査項目の詳細目的調査方法確認方法)
5. [調査結果の確認方法（クロスチェック・完了判定）](#5-調査結果の確認方法クロスチェック完了判定)
6. [調査結果の記録様式（テンプレート）](#6-調査結果の記録様式テンプレート)
7. [調査結果の移行設計への反映（WebLogic → Tomcat 対応観点）](#7-調査結果の移行設計への反映weblogic--tomcat-対応観点)
8. [付録](#8-付録)

---

## 1. 本書の目的と位置づけ

### 1.1 目的

本書は、現行の WebLogic Server 10.3.4.0 上で稼働しているアプリケーションとその実行環境を、**移行設計に必要な粒度で漏れなく把握する**ための調査手順を定めるものである。調査結果は、以下の設計書のインプットとして使用する。

- Tomcat 9 / Apache HTTP Server の構成設計書（コネクタ、スレッド、JNDI リソース、ログ、セッション等）
- アプリケーション改修設計書（WebLogic 依存箇所の除去、Java 11 対応）
- 移行方式設計書・移行手順書（デプロイ方式、環境固有パラメータ、切替手順）
- テスト計画書（性能ベースライン、確認観点）

### 1.2 移行の前提（プロジェクト情報より）

| 区分 | 現行 | 移行後 |
|---|---|---|
| OS（AP サーバ） | AWS RHEL 5.4 | AWS RHEL 9 |
| OS（Windows） | Windows Server 2008 R2 | Windows Server 2025 |
| AP サーバ | WebLogic Server 10.3.4.0 | Apache HTTP Server + Tomcat 9.0.x |
| Java | Java 8（※要確認。WLS 10.3.4 の認定 JDK は 1.6 系のため、実 JVM を必ず確認する） | Java 11（Amazon Corretto） |
| DB | Oracle 11g | RDS for Oracle 19c（S3 経由で移行） |
| 連携基盤 | ASTERIA 4.5.1 | ASTERIA Warp 2406（RHEL 上に導入） |
| フレームワーク | Spring MVC 3（Java EE Web アプリ） | 同左（改修範囲は調査結果により決定） |
| 環境 | dev / qa / honban（各環境 RHEL 1 台 + Windows 1 台） | 同左 |

### 1.3 対象読者と前提条件

- 対象読者: 現行調査担当者、調査結果のレビュー担当者、移行設計担当者
- 前提条件
  - 現行 AP サーバ（RHEL 5.4）への **OS ログイン（SSH）** が可能であること
  - **WebLogic 管理コンソール**（`http://<host>:7001/console`）の参照権限があること
  - 調査は **参照のみ**で行い、設定変更・再起動・デプロイ操作は行わない（特に honban）
  - honban での調査は作業申請・承認の上で実施し、負荷を伴う操作（診断イメージ取得、スレッドダンプ等）は事前合意した範囲のみ実施する

### 1.4 本書の使い方

1. 2 章で調査の進め方・ルール・変数定義を確認する
2. 3 章のマトリクスで調査項目の全体像と優先度を確認する
3. 4 章の手順に従い、環境ごとに証跡を取得する（付録 A の一括収集スクリプトを併用）
4. 5 章のクロスチェックで結果を確定させ、6 章の様式に記録する
5. 7 章で各結果が移行設計のどこに反映されるかを確認し、課題を起票する

---

## 2. 調査の進め方（全体方針）

### 2.1 4 つの情報源とクロスチェック

WebLogic の「設定」は複数の場所に分散しており、1 つの情報源だけでは実態を誤認する（例: config.xml 上の設定が起動引数で上書きされている、デプロイメントプランが記述子を上書きしている、等）。本調査では次の 4 つの情報源を必ず突合し、**一致して初めて「確認済」**とする。

| 情報源 | 具体例 | 特徴 |
|---|---|---|
| ① 設定ファイル | `config.xml`、`config/jdbc/*-jdbc.xml`、`setDomainEnv.sh`、`weblogic.xml`、`plan.xml` | 網羅的・機械的に差分比較できる。ただし上書きの可能性あり |
| ② 管理コンソール | Environment / Deployments / Services / Security Realms / Diagnostics の各画面 | 有効化された設定値・稼働状態・実績値（Monitoring）が見える |
| ③ 稼働中プロセス・ログ | `ps`、`/proc/<pid>/cmdline`、`netstat`、サーバログ（起動シーケンス）、アクセスログ | **実際に動いている値**。最終的な正とする |
| ④ アプリ成果物・ソース | 稼働中の EAR/WAR（展開物）、リポジトリのソース、記述子、Spring 設定 | WebLogic 依存箇所と、アプリが要求するリソースの根拠 |

### 2.2 調査の順序

| Step | 内容 | 主な対応カテゴリ（3 章） |
|---|---|---|
| Step 0 | 準備: 作業申請、アカウント確認、変数定義（2.5）、格納先作成（2.6） | — |
| Step 1 | 基盤・所在の特定: OS、JDK、WebLogic のインストール先、ドメインの所在、プロセスとポート | A、B |
| Step 2 | ドメイン構成の把握: config.xml、サーバ定義、JVM 引数、ログ・SSL・セキュリティ・JTA | C |
| Step 3 | アプリケーションとリソース: デプロイ一覧、JDBC/JNDI、その他リソース、記述子 | D、E、F、G |
| Step 4 | アプリ実装の依存調査: ソース・バイナリの WebLogic 依存、Java 11 影響、前段・外部連携、運用 | H、I、J、K |
| Step 5 | 実績値の取得: アクセス実績、JVM、スレッド、JDBC、OS リソース | L |
| Step 6 | クロスチェック・環境差分: 5 章の手順で確定、dev/qa/honban 差分 | M |
| Step 7 | 結果整理: 6 章の様式へ記録、不明点・課題の起票、レビュー | — |

### 2.3 証跡取得のルール

- コマンド出力は必ずファイルに保存する（`command > file 2>&1`、または `script` コマンドでセッション全体を記録）
- ファイル名規約: `<環境>_<項目No>_<内容>.<拡張子>`（例: `honban_E-2_jdbc_xml.txt`、`qa_C-2_console_servers.png`）
- 管理コンソールはスクリーンショットを取得し、URL と取得日時をファイル名または一覧に残す
- パスワードは記録しない。設定ファイル中の `password-encrypted` 等は暗号化済みのためそのまま保存してよいが、平文パスワードを含むファイル（`boot.properties` の平文版、独自スクリプト等）は **マスクしてから保存**する
- 実績値（Monitoring、WLST の Runtime 値）は「最終再起動からの累積」であるため、**稼働開始日時（Activation Time）を併記**する
- 収集日時・実行ユーザー・実行ホストを各証跡の先頭に残す（付録 A のスクリプトは自動で記録する）

### 2.4 禁止事項・注意事項

| 区分 | 内容 |
|---|---|
| 禁止（全環境） | 管理コンソールでの設定変更・保存（Lock & Edit）、サーバ・データソースの再起動/Reset、デプロイ/アンデプロイ、ファイル編集 |
| 禁止（honban） | `jmap -dump`（ヒープダンプ。停止時間が発生）、`-verbose:class` 等の JVM 引数変更、全ディスク対象の `find /`（I/O 負荷。対象ディレクトリを限定する） |
| 要承認（honban） | 診断イメージ取得（Diagnostic Image）、スレッドダンプ（`jstack`/`kill -3`）、WLST online 接続、Data Source の Test 実行 |
| 注意 | RHEL 5.4 は古いため `ss`、`jcmd`、`lsof` が無い場合がある。代替として `netstat`、`/proc/<pid>/`、`jinfo`/`jps` を使う。JVM が JRockit の場合は `jrcmd` を使う |
| 注意 | `find` はドメインディレクトリ・インストールディレクトリなど範囲を限定する。`tmp/_WL_user` 配下は大きい場合がある |
| 注意 | 3 環境のうち **honban を正**とし、dev/qa は honban との差分として整理する |

### 2.5 変数定義（本書のコマンド中で使用）

以下の変数は環境ごとに値が異なる。Step 1（B-2、B-3）で特定した値を記録し、以降のコマンドで使用する。

| 変数 | 意味 | 典型値（例） | 特定方法 |
|---|---|---|---|
| `MW_HOME` | Middleware ホーム | `/opt/Oracle/Middleware`、`/u01/app/oracle/Middleware` | `cat ~/bea/beahomelist`、`registry.xml` の所在 |
| `WL_HOME` | WebLogic ホーム | `$MW_HOME/wlserver_10.3` | 実プロセスの `-Dplatform.home` 引数（無ければ `-Dwls.home` / `-Dweblogic.home` から `/server` を除いたもの） |
| `DOMAIN_HOME` | ドメインディレクトリ | `$MW_HOME/user_projects/domains/<domain>` | 実プロセスの `cwd`（`readlink /proc/<pid>/cwd`）または `-Dweblogic.RootDirectory` 引数、`domain-registry.xml` |
| `SERVER_NAME` | サーバ名 | `AdminServer`、`ManagedServer_1` | 実プロセスの `-Dweblogic.Name` 引数 |
| `JAVA_HOME` | 実行 JDK | `$MW_HOME/jdk160_21`、`/usr/java/jdk1.8.0_xxx` | `readlink /proc/<pid>/exe` |
| `WLS_USER` | WebLogic 起動 OS ユーザー | `weblogic`、`oracle` | `ps -eo user,args \| grep weblogic.Server` |
| `PID` | WebLogic サーバプロセスの PID | — | `pgrep -f weblogic.Server` |

設定例（SSH ログイン後、調査開始時に実行する）:

```bash
export PID=$(pgrep -f weblogic.Server | head -1)
export DOMAIN_HOME=$(readlink /proc/$PID/cwd)
export WL_HOME=$(tr '\0' '\n' < /proc/$PID/cmdline | grep -m1 '^-Dplatform.home=' | sed 's#^-Dplatform.home=##')
[ -z "$WL_HOME" ] && export WL_HOME=$(tr '\0' '\n' < /proc/$PID/cmdline | grep -m1 '^-Dwls.home=' | sed 's#^-Dwls.home=##; s#/server/*$##')
export MW_HOME=$(dirname $WL_HOME)
export SERVER_NAME=$(tr '\0' '\n' < /proc/$PID/cmdline | grep -m1 '^-Dweblogic.Name=' | sed 's#^-Dweblogic.Name=##')
export JAVA_HOME=$(dirname $(dirname $(readlink /proc/$PID/exe)))
echo "PID=$PID DOMAIN_HOME=$DOMAIN_HOME WL_HOME=$WL_HOME MW_HOME=$MW_HOME SERVER_NAME=$SERVER_NAME JAVA_HOME=$JAVA_HOME"
```

※ `/proc/<pid>/cwd`、`/proc/<pid>/exe` の参照には、プロセスの所有ユーザーまたは root 権限が必要。WebLogic 起動ユーザーで作業することを推奨する。複数の Java プロセス（管理サーバ + 管理対象サーバ、Node Manager）がある場合は PID ごとに実施する。

### 2.6 調査結果の格納先

調査結果（証跡）は本リポジトリの `TomcatApache` フォルダ配下に、環境別・項目別に格納する。

```
sys_renewal/TomcatApache/
├── WebLogic現行環境調査手順書_ver1.md      ← 本書
├── WebLogic現行環境調査結果一覧_ver1.md    ← 6 章の様式で作成（次工程）
└── survey/
    ├── dev/
    │   ├── A_os/            ← カテゴリ別（A〜M）
    │   ├── B_install/
    │   ├── C_domain/        ← config ディレクトリのコピー等
    │   ├── D_deploy/
    │   ├── E_jdbc/
    │   ├── ...
    │   └── screenshots/     ← 管理コンソールのスクリーンショット
    ├── qa/
    └── honban/
```

※ 成果物（EAR/WAR）や大容量ログはリポジトリに入れず、別途共有ストレージに格納して所在のみ記録する。

---

## 3. 調査項目一覧（マトリクス）

凡例 — 重要度: **◎** 移行設計に必須 / **○** 設計精度向上のため推奨 / **△** 該当時のみ。情報源: ①設定ファイル ②管理コンソール ③プロセス・ログ ④成果物・ソース ⑤ヒアリング・外部（AWS 等）

### A. 基盤（OS・リソース・ネットワーク・OS 運用）

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| A-1 | OS バージョン、ホスト名、IP、タイムゾーン、ロケール | RHEL 9 の OS 設定（TZ/locale）、`file.encoding` の決定 | ③ | ◎ |
| A-2 | CPU/メモリ/ディスク、マウント（NFS 等）、EC2 インスタンスタイプ | Tomcat サイジング、JVM ヒープ、ファイル共有の移行方式 | ③⑤ | ◎ |
| A-3 | OS ユーザー/グループ、権限、`ulimit`、`sysctl` | Tomcat 実行ユーザー、`limits.conf`、カーネルパラメータ | ③ | ○ |
| A-4 | 待受ポート、ESTABLISHED 接続、iptables、`/etc/hosts`、DNS | ポート設計、セキュリティグループ、名前解決 | ③⑤ | ◎ |
| A-5 | 自動起動（init スクリプト、`rc.local`）、cron、logrotate | systemd ユニット設計、ジョブ移行 | ③ | ◎ |
| A-6 | 監視・バックアップ・運用エージェント | 監視設計（CloudWatch 等）、バックアップ設計 | ③⑤ | ○ |
| A-7 | インストール済パッケージ（httpd、Oracle クライアント等） | 前段 Apache の有無、OCI ドライバ利用の有無 | ③ | ○ |

### B. Java・WebLogic インストール

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| B-1 | JDK の種類（HotSpot/JRockit）、バージョン、配置 | Corretto 11 への JVM オプション読み替え、互換性リスク | ①③ | ◎ |
| B-2 | WebLogic バージョン、適用パッチ（BSU）、`MW_HOME`/`WL_HOME` | 現行の正確なベースライン、既知不具合の把握 | ①③ | ◎ |
| B-3 | ドメインの所在・数、ディレクトリ構成、ディスク使用量 | 移行対象範囲の確定 | ①③ | ◎ |
| B-4 | Node Manager の利用有無・設定 | 起動方式（systemd）設計 | ①③ | ○ |
| B-5 | 起動・停止スクリプト（標準/独自）、起動手順書 | systemd ユニット、`setenv.sh` 設計 | ①⑤ | ◎ |

### C. ドメイン・サーバ構成

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| C-1 | ドメイン基本情報（名前、バージョン、本番モード、管理サーバ） | 設計書の現行構成記載 | ①② | ◎ |
| C-2 | サーバ定義（Admin/Managed、リッスンアドレス/ポート、SSL ポート、管理ポート、ネットワークチャネル） | Tomcat コネクタ、Apache Listen、SG | ①②③ | ◎ |
| C-3 | クラスタ、マシン、仮想ホスト | 単一/複数構成の確定、セッション共有の要否 | ①② | ○ |
| C-4 | JVM 起動引数・システムプロパティ・環境変数（実プロセス） | `setenv.sh`（`CATALINA_OPTS`）の設計 | ①③ | ◎ |
| C-5 | スレッドプール、ワークマネージャ、過負荷保護、Stuck Thread 設定 | Tomcat `maxThreads`/`acceptCount`、StuckThreadDetectionValve | ①②③ | ◎ |
| C-6 | HTTP 設定（Keep-Alive、Max Post Size、Post Timeout、Frontend Host/Port、Plug-In Enabled、Charsets、デフォルト Web アプリ） | コネクタ属性、RemoteIpValve、`maxPostSize` | ①② | ◎ |
| C-7 | ログ設定（サーバログ/ドメインログ/アクセスログ/stdout、ローテーション、重大度） | `logging.properties`、AccessLogValve、logrotate | ①②③ | ◎ |
| C-8 | SSL/キーストア（証明書、有効期限、JSSE、ホスト名検証） | Apache mod_ssl 設計、証明書移行 | ①②③ | ○ |
| C-9 | セキュリティレルム（認証プロバイダ、ユーザー/グループ、ロール/ポリシー、資格情報マッピング） | Tomcat Realm 設計、アプリ認証方式の改修要否 | ①② | ◎ |
| C-10 | JTA 設定（タイムアウト等）と利用状況 | トランザクション管理方式（JTA → ローカル TX） | ①② | ◎ |
| C-11 | WLDF（診断モジュール）、SNMP、JMX リモート | 監視設計 | ①② | △ |
| C-12 | 起動クラス・シャットダウンクラス | `ServletContextListener` 等への移行 | ①② | △ |

### D. デプロイ済みアプリケーション

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| D-1 | デプロイ一覧（名前、EAR/WAR、ターゲット、ソースパス、ステージング、順序、状態） | 移行対象アプリの確定、Tomcat 配置設計 | ①②③ | ◎ |
| D-2 | デプロイ方式・リリース手順（コンソール/`weblogic.Deployer`/WLST/autodeploy） | Tomcat デプロイ手順設計 | ①⑤ | ◎ |
| D-3 | デプロイメントプラン（`plan.xml`）の有無と上書き内容 | 環境固有パラメータの外出し設計 | ①② | ◎ |
| D-4 | 共有ライブラリ（`library`、`library-ref`: JSF/JSTL 等） | WAR への同梱設計 | ①②④ | ◎ |
| D-5 | 稼働中成果物の同一性（ソースパス ⇔ 展開物 ⇔ リポジトリ） | 移行元ソースの確定 | ③④ | ◎ |
| D-6 | コンテキストルート、URL 体系（デフォルト Web アプリ、仮想ディレクトリ） | Apache ルーティング、Tomcat `path` | ①②④ | ◎ |

### E. JDBC データソース・JNDI（最重要）

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| E-1 | データソース一覧（名前、JNDI 名、ターゲット、種別: 通常/XA/Multi/GridLink） | `context.xml` の `<Resource>` 設計 | ①② | ◎ |
| E-2 | 接続先（URL、ドライバクラス、ユーザー、接続プロパティ、SID/サービス名、Thin/OCI） | RDS 19c 接続文字列、ドライバ選定 | ①② | ◎ |
| E-3 | プール設定（初期/最大/増分、テスト、タイムアウト、文キャッシュ、Init SQL、Shrink） | Tomcat JDBC Pool / DBCP2 属性 | ①② | ◎ |
| E-4 | トランザクション設定（`global-transactions-protocol`、XA 利用） | JTA 要否の判断 | ①② | ◎ |
| E-5 | JDBC ドライバの実体（ojdbc のバージョン・配置: WLS 同梱/DOMAIN lib/WEB-INF/lib） | ojdbc8/10（19c）への更新 | ①③④ | ◎ |
| E-6 | JNDI ツリーの実バインド名とアプリ側参照（`resource-ref`、`weblogic.xml`、Spring `jndi-lookup`） | `java:comp/env` 名の整合、web.xml 改修 | ②④ | ◎ |
| E-7 | 実績値（アクティブ接続数最大、待ち、リーク、再接続失敗、文キャッシュヒット率） | プールサイズの決定 | ② | ◎ |
| E-8 | アプリスコープ DS、JNDI を介さない直接接続（`BasicDataSource`、`DriverManager`） | 移行漏れ防止 | ④ | ○ |

### F. その他 Java EE リソース（コンテナ提供機能）

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| F-1 | JMS（JMS サーバ、モジュール、キュー/トピック、永続ストア、外部 JMS、MDB） | 代替（ActiveMQ 等）の要否 | ①②④ | ◎ |
| F-2 | メールセッション（`mail-session`） | Tomcat `javax.mail.Session` リソース | ①②④ | ○ |
| F-3 | EJB、RMI/T3、IIOP、外部 JNDI プロバイダ | Tomcat 非対応機能の代替設計 | ①②④ | ◎ |
| F-4 | Web サービス（JAX-WS/JAX-RPC、`weblogic-webservices.xml`） | 実装の差し替え要否 | ④ | △ |
| F-5 | ワークマネージャ、CommonJ Work/Timer のアプリ利用 | `ThreadPoolTaskExecutor` 等への置換 | ①④ | ○ |
| F-6 | 永続ストア（file-store/jdbc-store）、トランザクションログ | 移行不要の確認（JMS/JTA 利用時のみ） | ①② | △ |
| F-7 | JPA/JAXB/JSF 等コンテナ提供ライブラリ | WAR 同梱設計 | ①④ | ○ |

### G. Web アプリケーション記述子（WebLogic 固有設定）

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| G-1 | `web.xml`（仕様版、サーブレット/フィルタ/リスナー、`session-config`、`resource-ref`、`env-entry`、`security-constraint`、`login-config`、`error-page`、`mime-mapping`、`jsp-config`） | web.xml 改修設計 | ④ | ◎ |
| G-2 | `weblogic.xml`（全要素） | `context.xml`/`web.xml`/Tomcat 設定への読み替え | ④ | ◎ |
| G-3 | `weblogic-application.xml` / `application.xml`（EAR の場合） | EAR → WAR 化設計 | ④ | ◎ |
| G-4 | セッション設定（タイムアウト、Cookie 名/パス/secure/httponly、URL リライト、永続化） | Tomcat セッション設計、前段との Cookie 整合 | ②④ | ◎ |
| G-5 | 文字コード設定（`charset-params`、`file.encoding`、`webapp.encoding.default`、JSP `pageEncoding`、フィルタ） | `URIEncoding`、`CharacterEncodingFilter` | ①④ | ◎ |
| G-6 | クラスローディング設定（`prefer-web-inf-classes`、`prefer-application-packages`） | Tomcat（子優先）との差異確認 | ④ | ○ |

### H. アプリケーション実装の WebLogic / Java 依存（ソース・バイナリ）

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| H-1 | `weblogic.*`/`commonj.*`/`com.bea.*` の直接利用（Java、JSP、設定、プロパティ） | 改修箇所一覧 | ④ | ◎ |
| H-2 | Spring 設定の WebLogic 依存（`WebLogicJtaTransactionManager`、`WorkManagerTaskExecutor`、`LoadTimeWeaver` 等） | Spring 設定改修 | ④ | ◎ |
| H-3 | JNDI 参照方式（`java:comp/env` の有無、`resource-ref` 有無、直接名） | 名前解決の改修 | ④ | ◎ |
| H-4 | トランザクション管理方式（JTA/`UserTransaction`/ローカル） | `DataSourceTransactionManager` 化の可否 | ④ | ◎ |
| H-5 | コンテナ提供ライブラリへの依存（`jdeps` 未解決パッケージ、`WEB-INF/lib` 一覧と版） | 同梱ライブラリ設計 | ④ | ◎ |
| H-6 | Java 11 影響（削除モジュール、内部 API、コンパイルターゲット、Spring 3 の対応状況） | Java 対応改修の範囲 | ④ | ◎ |
| H-7 | ファイルシステム依存（絶対パス、`getRealPath`、一時領域、アップロード先、ログ出力先） | ディレクトリ設計、権限設計 | ④③ | ◎ |
| H-8 | プロキシ・クライアント IP・スキーム依存（`WL-Proxy-Client-IP`、`X-Forwarded-*`、`isSecure`） | RemoteIpValve 設計 | ④ | ○ |
| H-9 | JSP の互換性（JSP 数、タグライブラリ、WLS 固有の緩い記述、プリコンパイル） | Jasper でのコンパイル確認計画 | ④ | ○ |
| H-10 | ロギング実装（log4j/commons-logging/JUL、設定ファイル、出力先、WLS ロギングブリッジ） | ログ設計 | ④ | ◎ |
| H-11 | スケジューラ・非同期処理（Quartz、`Timer`、独自スレッド、`@Scheduled`） | 多重起動・停止処理の設計 | ④ | ○ |
| H-12 | バッチ・外部プログラムの WebLogic 依存（`t3://`、`wlfullclient.jar`、`weblogic.jar` 参照） | バッチ改修 | ③④ | ◎ |

### I. 前段 Web サーバ・ロードバランサ

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| I-1 | 前段構成（ELB / Apache / 直接、SSL 終端箇所、経路） | Apache 配置と SSL 設計 | ③⑤ | ◎ |
| I-2 | Apache 設定（版、`httpd.conf`、vhost、`mod_wl` 設定、rewrite、静的コンテンツ、アクセス制御、ログ） | Apache 2.4 設定設計（`mod_proxy` 化） | ①③ | ◎ |
| I-3 | ELB/SG/DNS（リスナー、ヘルスチェック、アイドルタイムアウト、スティッキー、証明書） | AWS 側設計 | ⑤ | ○ |

### J. 外部連携

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| J-1 | Oracle DB の所在と接続経路（ホスト、ポート、SID/サービス名、DB リンク、キャラクタセット） | RDS 接続設計 | ①③⑤ | ◎ |
| J-2 | ASTERIA との連携方式（HTTP/ファイル/DB/JMS、方向、ポーリング先） | 連携 I/F 設計 | ④⑤ | ◎ |
| J-3 | Windows Server 2008 R2 との連携（ファイル共有、FTP、SMB、スケジュール） | 連携 I/F 設計 | ③⑤ | ◎ |
| J-4 | その他（SMTP、外部 API、LDAP、S3、プロキシ、NTP） | ネットワーク・SG 設計 | ③④⑤ | ○ |

### K. 運用・ログ・監視

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| K-1 | ログ一覧（種類、パス、形式、ローテーション、保管期間、参照者） | ログ設計 | ①③⑤ | ◎ |
| K-2 | 監視項目（プロセス、ポート、URL、ログ監視キーワード、閾値） | 監視設計 | ⑤ | ◎ |
| K-3 | バックアップ・リストア対象 | バックアップ設計 | ⑤ | ○ |
| K-4 | 運用手順書（起動停止、リリース、障害対応、パスワード変更、証明書更新） | 運用手順書改版 | ⑤ | ◎ |
| K-5 | 定期ジョブ（cron、WLS Timer、Quartz） | ジョブ移行 | ③④ | ◎ |

### L. 実績値・性能ベースライン

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| L-1 | アクセス実績（日次件数、ピーク分間件数、URL 別、ステータス別、応答時間） | 性能要件、テストシナリオ | ③ | ◎ |
| L-2 | JVM 実績（ヒープ使用量、GC ログ、Full GC 頻度、スレッド数） | ヒープ・GC 設計 | ②③ | ◎ |
| L-3 | スレッドプール・セッション実績（同時実行最大、Hogging、キュー長、オープンセッション最大） | `maxThreads`、セッション設計 | ② | ◎ |
| L-4 | JDBC・JTA 実績（E-7 と同一、TX 件数/タイムアウト件数） | プールサイズ、TX タイムアウト | ② | ◎ |
| L-5 | OS リソース実績（`sar`、CloudWatch） | インスタンスサイジング | ③⑤ | ○ |
| L-6 | エラー・警告の傾向（サーバログの BEA-ID 集計、Stuck Thread、OOM） | 既知課題の引き継ぎ | ③ | ○ |

### M. 環境差分（dev / qa / honban）

| No | 調査項目 | 移行設計での使い道 | 情報源 | 重要度 |
|---|---|---|---|---|
| M-1 | 設定ファイル差分（`config.xml`、`*-jdbc.xml`、`setDomainEnv.sh`、`weblogic.xml`、`plan.xml`、httpd） | 環境別パラメータ設計 | ① | ◎ |
| M-2 | 環境固有値一覧（ホスト、ポート、URL、JNDI、パス、認証情報の所在） | パラメータシート | ①② | ◎ |
| M-3 | 環境ごとの構成差（サーバ台数、Apache 有無、監視、パッチ） | 環境別設計・構成ドリフトの是正 | ①②⑤ | ○ |

---
## 4. 調査項目の詳細（目的・調査方法・確認方法）

各カテゴリについて「調査方法」（コマンド・設定ファイル・管理コンソール画面）と「確認方法」（何をもって確認済とするか）を示す。コマンドは WebLogic 起動ユーザーで SSH ログインし、2.5 の変数を設定済みであることを前提とする。管理コンソールの画面パスは付録 C にまとめている。

### 4.A 基盤（OS・リソース・ネットワーク・OS 運用）

#### 調査方法

**A-1 OS 基本情報**

```bash
cat /etc/redhat-release; uname -a; hostname; hostname -f
cat /etc/hosts; cat /etc/resolv.conf; cat /etc/sysconfig/network
date; cat /etc/sysconfig/clock; ls -l /etc/localtime          # タイムゾーン
cat /etc/sysconfig/i18n; locale                                # ロケール（LANG）
```

**A-2 リソース・マウント**

```bash
grep -c processor /proc/cpuinfo; grep 'model name' /proc/cpuinfo | sort -u
free -m; swapon -s
df -hP; mount; cat /etc/fstab                                  # NFS/CIFS マウントの有無を確認
du -sh $MW_HOME $DOMAIN_HOME 2>/dev/null
# EC2 インスタンスタイプ（インスタンスメタデータ）
curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-type; echo
curl -s --max-time 3 http://169.254.169.254/latest/meta-data/local-ipv4; echo
```

**A-3 ユーザー・権限・カーネルパラメータ**

```bash
id; id $WLS_USER
egrep -v 'nologin|/bin/false' /etc/passwd
egrep 'weblogic|wls|oracle|bea|apache|tomcat' /etc/group
cat /etc/security/limits.conf; ls /etc/security/limits.d/ 2>/dev/null
ulimit -a                                                      # 起動ユーザーで実行
cat /proc/$PID/limits                                          # 実プロセスに効いている値
sysctl -a 2>/dev/null | egrep 'ip_local_port_range|tcp_keepalive|somaxconn|tcp_max_syn_backlog|file-max|shmmax|swappiness'
ls -la $DOMAIN_HOME; ls -la $DOMAIN_HOME/servers/*/logs | head  # 所有者・権限
```

**A-4 ネットワーク**

```bash
/sbin/ifconfig -a; netstat -rn
netstat -tlnp 2>/dev/null | sort -k4                           # 待受ポート（root で実行するとプロセス名が出る）
netstat -anp 2>/dev/null | grep ESTABLISHED | awk '{print $4, $5, $7}' | sort | uniq -c | sort -rn | head -50   # 接続元・接続先の傾向
/sbin/iptables -L -n 2>/dev/null; cat /etc/sysconfig/iptables 2>/dev/null
getenforce 2>/dev/null
```

※ AWS セキュリティグループ、ELB、Route 53 は AWS 管理コンソールまたは AWS CLI で確認する（I-3 参照）。

**A-5 自動起動・cron・logrotate**

```bash
chkconfig --list 2>/dev/null | grep -v off$ ; ls -la /etc/init.d/
cat /etc/rc.local; ls -la /etc/rc3.d/ /etc/rc5.d/
grep -l -i -E 'weblogic|startWebLogic|nodemanager|httpd|java' /etc/init.d/* /etc/rc.local 2>/dev/null
# cron（root で実行。root でなければ自ユーザーの crontab -l のみ）
for u in $(cut -d: -f1 /etc/passwd); do c=$(crontab -l -u $u 2>/dev/null); [ -n "$c" ] && { echo "=== $u"; echo "$c"; }; done
cat /etc/crontab; ls -la /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; cat /etc/cron.d/* 2>/dev/null
cat /etc/logrotate.conf; cat /etc/logrotate.d/* 2>/dev/null
```

**A-6 監視・バックアップ・運用エージェント**

```bash
ps -ef | egrep -i 'zabbix|nagios|nrpe|hinemos|jp1|amazon-ssm|cloudwatch|awslogs|fluentd|td-agent|splunk|datadog|snmpd|newrelic|netbackup|arcserve|rsync|backup' | grep -v egrep
chkconfig --list 2>/dev/null | egrep -i 'zabbix|nagios|nrpe|hinemos|jp1|ssm|awslogs|snmpd'
ls /etc/zabbix /etc/nagios /etc/awslogs /etc/snmp 2>/dev/null
```

**A-7 インストール済パッケージ**

```bash
rpm -qa | sort > <証跡ファイル>
rpm -qa | egrep -i 'httpd|mod_ssl|oracle|instantclient|java|jdk|jre|openssl|sysstat|lsof|unzip'
which httpd sqlplus tnsping lsof jstack jinfo jps 2>/dev/null
env | egrep 'ORACLE|TNS_ADMIN|LD_LIBRARY_PATH'; find / -xdev -maxdepth 4 -name tnsnames.ora 2>/dev/null
```

#### 確認方法

- A-1: `date` の出力（JST）と `/etc/sysconfig/clock` の `ZONE`、および実プロセスの `-Duser.timezone`（C-4）が整合していること。`LANG` と実プロセスの `file.encoding`（C-4）の関係を記録する（例: `LANG=ja_JP.UTF-8` だが `-Dfile.encoding=MS932` 指定あり、等）。
- A-2: NFS/CIFS マウントがある場合は、用途（アプリの入出力/ログ/連携）をアプリ側の絶対パス調査（H-7）と突合する。
- A-3: `ulimit -a` と `/proc/$PID/limits` が一致すること（起動スクリプトで `ulimit` を変更している場合は不一致となる → B-5 に記録）。
- A-4: `netstat -tlnp` の待受ポートを、config.xml の `listen-port`（C-2）と起動ログ `BEA-002613`（5.2）で説明できること。説明できないポートは所有プロセスを特定し、用途を記録する。
- A-5: WebLogic の自動起動有無（init スクリプト / Node Manager / 手動）を B-4、B-5 と整合させる。cron のジョブは K-5 に転記し、`weblogic.jar` や `t3://` を使うものは H-12 に転記する。

### 4.B Java・WebLogic インストール

#### 調査方法

**B-1 JDK**

```bash
readlink /proc/$PID/exe                                        # 実際に動いている java
$JAVA_HOME/bin/java -version 2>&1                              # HotSpot か JRockit か
ls -la $MW_HOME | egrep -i 'jdk|jrockit'                       # WLS 同梱 JDK
egrep -n 'JAVA_HOME|JAVA_VENDOR|VM_TYPE' $WL_HOME/common/bin/commEnv.sh
egrep -n 'JAVA_HOME|JAVA_VENDOR|BEA_JAVA_HOME|SUN_JAVA_HOME' $DOMAIN_HOME/bin/setDomainEnv.sh
grep -h 'BEA-000377' $DOMAIN_HOME/servers/$SERVER_NAME/logs/$SERVER_NAME.log* | tail -3   # 起動ログの JVM 表示
rpm -qa | egrep -i 'jdk|java'; ls -la /usr/java /usr/lib/jvm 2>/dev/null
```

**B-2 WebLogic バージョン・パッチ**

```bash
cat $WL_HOME/.product.properties                               # WLS_PRODUCT_VERSION=10.3.4.0
grep -i 'name=\|version=' $MW_HOME/registry.xml | head -30
cat $MW_HOME/domain-registry.xml
cat ~/bea/beahomelist 2>/dev/null; cat /home/*/bea/beahomelist /root/bea/beahomelist 2>/dev/null
ls -la $MW_HOME $WL_HOME $MW_HOME/patch_wls*/patch_jars 2>/dev/null
# 適用パッチ（Smart Update / BSU）
cd $MW_HOME/utils/bsu && ./bsu.sh -prod_dir=$WL_HOME -status=applied -verbose -view
# WLS 自身による表示（バージョン + パッチ ID）
( . $WL_HOME/server/bin/setWLSEnv.sh > /dev/null 2>&1; java weblogic.version -verbose )
grep -h 'BEA-141107' $DOMAIN_HOME/servers/$SERVER_NAME/logs/$SERVER_NAME.log* | tail -2   # 起動ログの版表示
```

**B-3 ドメインの所在・構成**

```bash
echo $DOMAIN_HOME; cat $MW_HOME/domain-registry.xml
ls -la $DOMAIN_HOME; ls -la $DOMAIN_HOME/config $DOMAIN_HOME/servers
find $DOMAIN_HOME -maxdepth 3 -not -path '*/tmp/*' -not -path '*/logs/*' | sort
du -sh $DOMAIN_HOME/* $DOMAIN_HOME/servers/* 2>/dev/null
ls -la $DOMAIN_HOME/lib                                        # ドメインライブラリ（全サーバのクラスパスに乗る）
ls -la $DOMAIN_HOME/autodeploy 2>/dev/null                     # 開発モードの自動デプロイ
ls -la $DOMAIN_HOME/servers/*/security/                        # boot.properties の有無
# 他ドメインの存在確認（範囲を限定して find）
find $MW_HOME /opt /u01 /home -maxdepth 6 -name config.xml -path '*/config/config.xml' 2>/dev/null
```

**B-4 Node Manager**

```bash
ps -ef | grep -i '[N]odeManager'
netstat -tlnp 2>/dev/null | grep 5556
cat $WL_HOME/common/nodemanager/nodemanager.properties $WL_HOME/common/nodemanager/nodemanager.domains 2>/dev/null
ls -la $WL_HOME/common/nodemanager/ $WL_HOME/server/bin/startNodeManager.sh
grep -c '<machine>' $DOMAIN_HOME/config/config.xml; grep -A6 '<machine>' $DOMAIN_HOME/config/config.xml
```

**B-5 起動・停止スクリプト**

```bash
ls -la $DOMAIN_HOME/*.sh $DOMAIN_HOME/bin/
cat $DOMAIN_HOME/bin/setDomainEnv.sh $DOMAIN_HOME/bin/startWebLogic.sh $DOMAIN_HOME/bin/startManagedWebLogic.sh $DOMAIN_HOME/bin/stopWebLogic.sh
cat $DOMAIN_HOME/startWebLogic.sh $DOMAIN_HOME/startManagedWebLogic.sh 2>/dev/null
# 独自ラッパースクリプト（init.d、ホームディレクトリ、/opt 等）
grep -l -E 'startWebLogic|weblogic\.Server|startManagedWebLogic|stopWebLogic' /etc/init.d/* /etc/rc.local /home/*/*.sh /opt/*/*.sh /usr/local/bin/* 2>/dev/null
# setDomainEnv.sh を読み込んだ後の実効値（サブシェルで実行）
( . $DOMAIN_HOME/bin/setDomainEnv.sh > /dev/null 2>&1; env | egrep '^(JAVA_HOME|JAVA_VENDOR|MEM_ARGS|USER_MEM_ARGS|JAVA_OPTIONS|JAVA_PROPERTIES|EXTRA_JAVA_PROPERTIES|CLASSPATH|PRE_CLASSPATH|POST_CLASSPATH|PRODUCTION_MODE|WL_HOME|DOMAIN_HOME|LD_LIBRARY_PATH|PATH|WLS_REDIRECT_LOG)=' )
```

#### 確認方法

- B-1: 「実プロセスの `java`（`readlink /proc/$PID/exe`）」を正とし、`setDomainEnv.sh`/`commEnv.sh` の `JAVA_HOME` と起動ログ `BEA-000377` の 3 者が一致すること。プロジェクト資料上「Java 8」とされているが、WLS 10.3.4 の同梱 JDK は 1.6 系（HotSpot `jdk160_21` または JRockit R28）であるため、**実 JVM の種類とバージョンを確定し、資料と異なる場合は課題として記録**する。JRockit の場合、`-Xns`/`-Xgc:`/`-XXcompressedRefs` 等 HotSpot に存在しない引数の読み替えが必要になる。
- B-2: `.product.properties`、`registry.xml`、`java weblogic.version`、起動ログ `BEA-141107` の版が一致すること。適用パッチ一覧は BSU の出力（パッチ ID と説明）を証跡とする。
- B-3: 稼働中プロセスの `cwd` がドメインディレクトリであること。複数ドメイン・複数サーバがある場合、それぞれの用途（本番系/検証系/未使用）をヒアリングで確定する。`$DOMAIN_HOME/lib` の JAR は「全アプリから見えるライブラリ」であるため、内容を H-5 に転記する。
- B-4: Node Manager 経由の起動の場合、JVM 引数はコンソールの Servers > [server] > Configuration > Server Start タブ（`<server-start>` 要素）に定義されており、`setDomainEnv.sh` とは別管理である点に注意し、C-4 で実プロセスの引数と突合する。
- B-5: 起動手順書（K-4）の記載と、実際の init スクリプト・自動起動設定（A-5）が一致していること。`ulimit`、`umask`、環境変数の設定箇所を特定し、systemd 化の際の要件として記録する。

### 4.C ドメイン・サーバ構成

#### 調査方法

**C-1〜C-3、C-5〜C-7、C-10〜C-12 config.xml の読み取り**

`config.xml` は全体をコピーして証跡とし（`cp -p $DOMAIN_HOME/config/config.xml <証跡>`）、以下の要素を抽出して 6 章の様式に転記する。

```bash
CFG=$DOMAIN_HOME/config/config.xml
# C-1 ドメイン基本情報
sed -n '1,20p' $CFG                                            # <name>、<domain-version>
grep -E '<domain-version>|<production-mode-enabled>|<admin-server-name>|<administration-port-enabled>|<administration-port>' $CFG
# C-2 サーバ定義（<server> ブロックを丸ごと確認）
awk '/<server>/,/<\/server>/' $CFG
grep -E '<listen-address>|<listen-port>|<listen-port-enabled>|<ssl>|<enabled>|<network-access-point>|<protocol>|<public-address>|<public-port>' $CFG
# C-3 クラスタ・マシン・仮想ホスト
awk '/<cluster>/,/<\/cluster>/' $CFG; awk '/<machine>/,/<\/machine>/' $CFG; awk '/<virtual-host>/,/<\/virtual-host>/' $CFG
# C-5 スレッド・ワークマネージャ・過負荷保護
awk '/<self-tuning>/,/<\/self-tuning>/' $CFG                   # <work-manager>、<max-threads-constraint>、<min-threads-constraint>、<capacity>
grep -E '<stuck-thread-max-time>|<stuck-thread-timer-interval>|<accept-backlog>|<login-timeout-millis>|<idle-connection-timeout>|<complete-message-timeout>|<max-message-size>|<native-io-enabled>|<max-open-sock-count>' $CFG
awk '/<overload-protection>/,/<\/overload-protection>/' $CFG
# C-6 HTTP 設定
awk '/<web-server>/,/<\/web-server>/' $CFG                      # <frontend-host>、<frontend-http-port>、<keep-alive-*>、<max-post-size>、<max-post-time-secs>、<post-timeout-secs>、<default-web-app-context-root>、<charsets>、<send-server-header-enabled>
awk '/<web-app-container>/,/<\/web-app-container>/' $CFG        # ドメインレベルの Web コンテナ設定
grep -E '<weblogic-plugin-enabled>|<client-cert-proxy-enabled>|<http-trace-support-enabled>|<x-powered-by-header-level>|<auth-cookie-enabled>|<relogin-enabled>|<servlet-reload-check-secs>|<jsp-compiler-backwards-compatible>|<mime-mapping-file>' $CFG
# C-7 ログ設定
awk '/<log>/,/<\/log>/' $CFG                                    # サーバログ・ドメインログ: <file-name>、<rotation-type>、<file-min-size>、<rotation-time>、<file-count>、<log-file-severity>、<stdout-severity>、<redirect-stdout-to-server-log-enabled>
awk '/<web-server-log>/,/<\/web-server-log>/' $CFG              # アクセスログ: <file-name>、<log-file-format>（common/extended）、<elf-fields>、<rotation-type>
# C-10 JTA
awk '/<jta>/,/<\/jta>/' $CFG                                    # <timeout-seconds>、<abandon-timeout-seconds>、<max-transactions>
# C-11 WLDF / SNMP / JMX
awk '/<wldf-system-resource>/,/<\/wldf-system-resource>/' $CFG; ls -la $DOMAIN_HOME/config/diagnostics/ 2>/dev/null
awk '/<snmp-agent>/,/<\/snmp-agent>/' $CFG; awk '/<jmx>/,/<\/jmx>/' $CFG
# C-12 起動・シャットダウンクラス
awk '/<startup-class>/,/<\/startup-class>/' $CFG; awk '/<shutdown-class>/,/<\/shutdown-class>/' $CFG
# 全体の要素種別の棚卸し（想定外の要素を見落とさないため）
grep -oE '^\s*<[a-z][a-z0-9-]*>' $CFG | sed 's/^\s*//' | sort | uniq -c | sort -rn
```

管理コンソール（参照のみ）:

- C-1: 左ツリーのドメイン名 > Configuration > General（Production Mode）、Monitoring > General
- C-2: Environment > Servers > [server] > Configuration > General（Listen Address/Port、SSL Listen Port、Machine、Cluster）、Protocols > Channels
- C-3: Environment > Clusters / Machines / Virtual Hosts
- C-5: Environment > Work Managers、Servers > [server] > Configuration > Tuning / Overload、Monitoring > Threads / Workload
- C-6: Servers > [server] > Protocols > HTTP（Frontend Host/Port、Max Post Size、Post Timeout、Keep Alive）、Configuration > General > Advanced（WebLogic Plug-In Enabled）
- C-7: Servers > [server] > Logging > General / HTTP / Data Source、ドメイン名 > Configuration > Logging
- C-10: Services > JTA
- C-11: Diagnostics > Diagnostic Modules / SNMP、ドメイン名 > Configuration > General > Advanced（JMX 関連はドメインの Configuration > JMX ではなく `config.xml` の `<jmx>` で確認）
- C-12: Environment > Startup and Shutdown Classes

**C-4 JVM 起動引数・システムプロパティ・環境変数（実プロセス）**

```bash
tr '\0' '\n' < /proc/$PID/cmdline                              # 実際の起動引数（最も信頼できる）
tr '\0' '\n' < /proc/$PID/environ | sort                       # 実際の環境変数（同一ユーザーまたは root）
ps -eo user,pid,ppid,lstart,etime,rss,vsz,pcpu,pmem,args | grep '[w]eblogic.Server'
$JAVA_HOME/bin/jps -lvm 2>/dev/null                            # HotSpot の場合
$JAVA_HOME/bin/jinfo -flags $PID 2>/dev/null; $JAVA_HOME/bin/jinfo -sysprops $PID 2>/dev/null
$JAVA_HOME/bin/jrcmd $PID command_line 2>/dev/null; $JAVA_HOME/bin/jrcmd $PID print_properties 2>/dev/null   # JRockit の場合
# Node Manager 起動の場合の引数定義
awk '/<server-start>/,/<\/server-start>/' $DOMAIN_HOME/config/config.xml
```

抽出して記録する引数（6.5 の様式）: `-Xms`/`-Xmx`/`-Xmn`/`-XX:MaxPermSize`/GC 種別/`-Xloggc`、`-Dfile.encoding`、`-Duser.timezone`、`-Duser.language`/`-Duser.country`、`-Djava.security.egd`、`-Dweblogic.*`（`ProductionModeEnabled`、`Name`、`management.server`、`ListenPort`、`threadpool.*`、`http.*`、`servlet.*`、`security.SSL.*`、`log.*`、`system.BootIdentityFile`）、`-Djavax.net.ssl.*`、`-Dhttp.proxy*`/`-Dhttps.proxy*`、`-Doracle.*`、`-DUseSunHttpHandler`、`-Dcom.sun.management.jmxremote*`、アプリ独自の `-D`（設定ファイルパス、環境名等）、`-classpath` の内容（`PRE_CLASSPATH`/`POST_CLASSPATH` で追加された JAR）。

**C-8 SSL / キーストア**

```bash
awk '/<ssl>/,/<\/ssl>/' $DOMAIN_HOME/config/config.xml
grep -E '<key-stores>|<custom-identity-key-store-file-name>|<custom-identity-key-store-type>|<custom-trust-key-store-file-name>|<java-standard-trust-key-store-pass-phrase-encrypted>|<server-private-key-alias>|<hostname-verifier>|<hostname-verification-ignored>|<jsse-enabled>|<two-way-ssl-enabled>|<client-certificate-enforced>' $DOMAIN_HOME/config/config.xml
tr '\0' '\n' < /proc/$PID/cmdline | grep -E 'ssl|SSL|trustStore|keyStore'
# キーストアの内容（パスフレーズは運用担当から入手。Demo キーストアの場合は DemoIdentityKeyStorePassPhrase / DemoTrustKeyStorePassPhrase）
$JAVA_HOME/bin/keytool -list -v -keystore <keystore path> | egrep 'Alias|Owner|Issuer|Valid|Certificate\[|SHA1'
ls -la $WL_HOME/server/lib/DemoIdentity.jks $WL_HOME/server/lib/DemoTrust.jks $JAVA_HOME/jre/lib/security/cacerts
grep -h -E 'BEA-090171|BEA-090169|BEA-090170|BEA-090905|BEA-090906' $DOMAIN_HOME/servers/$SERVER_NAME/logs/$SERVER_NAME.log* | sort -u   # 起動時に読み込まれたキーストア
```

**C-9 セキュリティレルム**

```bash
awk '/<security-configuration>/,/<\/security-configuration>/' $DOMAIN_HOME/config/config.xml   # <realm> 配下の各プロバイダ（sec:authentication-provider の xsi:type）
ls -la $DOMAIN_HOME/security/ $DOMAIN_HOME/servers/*/data/ldap/ldapfiles/ 2>/dev/null           # 埋め込み LDAP の有無・サイズ・更新日時
grep -c 'password-encrypted' $DOMAIN_HOME/config/config.xml
```

管理コンソール: Security Realms > myrealm > Providers（Authentication / Authorization / Role Mapping / Credential Mapping / Auditing の各プロバイダ種別）、Users and Groups（ユーザー・グループの一覧をスクリーンショットまたはエクスポート）、Roles and Policies（アプリに対するポリシーの有無）、Credential Mappings。ユーザーが多い場合は Migration > Export でエクスポートする（サーバ上にファイルを書き出すため、honban では要承認）。

#### 確認方法

- C-2: `listen-port`（config.xml）⇔ `netstat -tlnp`（A-4）⇔ 起動ログ `BEA-002613`（Channel "Default" is now listening on ...）⇔ コンソール Servers 画面の 4 者が一致すること。`-Dweblogic.ListenPort` 等の起動引数による上書きがないことを C-4 で確認する。
- C-4: 実プロセスの引数（`/proc/$PID/cmdline`）を正とし、`setDomainEnv.sh`（B-5）または `<server-start>`（Node Manager 起動時）から説明できること。説明できない引数は独自ラッパースクリプト（B-5）を探す。
- C-5: 設定値（Stuck Thread Max Time 等）と実績（L-3、L-6 の `BEA-000337` Stuck Thread 発生回数）を併記し、Tomcat の `maxThreads` と StuckThreadDetectionValve の閾値決定に使う。
- C-6: `max-post-size` が未設定（WebLogic の既定は無制限）の場合、Tomcat の既定 `maxPostSize`（2MB）でリクエストが失敗する可能性があるため、アプリの最大 POST サイズ（アップロード機能の有無）を H-7 とあわせて確認する。`weblogic-plugin-enabled=true` の場合は前段プロキシ経由でクライアント IP を取得している（H-8）。
- C-7: ログ設定（config.xml）⇔ 実際のログファイル（`ls -la $DOMAIN_HOME/servers/*/logs/`）⇔ logrotate（A-5）の三者で、出力先・ローテーション・世代数が一致すること。`stdout`（`.out` ファイル）の肥大化や、独自ローテーション（cron）の有無を記録する。
- C-8: 証明書の有効期限・発行者・SAN を記録し、Apache 側で継続利用するか新規発行するかの判断材料とする。SSL が前段（ELB/Apache）で終端している場合は「WebLogic 側 SSL は未使用」として記録する。
- C-9: 認証プロバイダが `DefaultAuthenticator`（埋め込み LDAP）のみで、かつアプリの `web.xml` に `security-constraint`/`login-config` がない（G-1）場合、レルムはコンソール管理者用のみと判断できる。アプリがコンテナ認証（`request.getRemoteUser()`、`isUserInRole()`、`ServletAuthentication`）を使っている場合（H-1、H-2）、ユーザー/グループ/ロール割当の全量が移行対象となる。
- C-10: `<jta>` の設定値と、E-4（`global-transactions-protocol`）、H-4（アプリのトランザクション管理方式）を突合し、「JTA を実際に使っているか」を判定する。使っていなければ Tomcat 側は JTA 不要（Spring の `DataSourceTransactionManager`）となる。

### 4.D デプロイ済みアプリケーション

#### 調査方法

**D-1、D-3、D-4、D-6 デプロイ定義**

```bash
CFG=$DOMAIN_HOME/config/config.xml
awk '/<app-deployment>/,/<\/app-deployment>/' $CFG            # <name>、<target>、<module-type>、<source-path>、<staging-mode>、<plan-dir>/<plan-path>、<security-dd-model>、<deployment-order>
awk '/<library>/,/<\/library>/' $CFG                          # 共有ライブラリ（jsf-1.2、jstl-1.2 など）
ls -la $WL_HOME/common/deployable-libraries/ 2>/dev/null       # WLS 同梱の共有ライブラリ
ls -la $DOMAIN_HOME/config/deployments/ 2>/dev/null            # 設定ディレクトリ側のデプロイ情報
# ソースパス（相対パスは DOMAIN_HOME 基準）の実体
for sp in $(sed -n 's#.*<source-path>\(.*\)</source-path>.*#\1#p' $CFG); do
  case "$sp" in /*) p="$sp";; *) p="$DOMAIN_HOME/$sp";; esac
  echo "=== $p"; ls -la "$p"; [ -f "$p" ] && { md5sum "$p"; unzip -l "$p" | tail -1; }
done
# デプロイメントプラン
for pp in $(sed -n 's#.*<plan-path>\(.*\)</plan-path>.*#\1#p' $CFG) $(sed -n 's#.*<plan-dir>\(.*\)</plan-dir>.*#\1#p' $CFG); do echo "=== $pp"; ls -la "$pp" 2>/dev/null; done
find $DOMAIN_HOME -maxdepth 6 -name 'plan.xml' -not -path '*/tmp/*' 2>/dev/null | xargs -I{} sh -c 'echo "=== {}"; cat {}'
# サーバ側の展開物・ステージング・アップロード
ls -la $DOMAIN_HOME/servers/*/stage/ $DOMAIN_HOME/servers/*/upload/ 2>/dev/null
ls -la $DOMAIN_HOME/servers/*/tmp/_WL_user/
find $DOMAIN_HOME/servers/*/tmp/_WL_user -maxdepth 4 -type d | sort
```

管理コンソール: Deployments（一覧: Name、State、Health、Type、Deployment Order、Targets）。各アプリの Overview（Context Root、Path、Deployment Plan、Staging Mode、Security Model）、Deployment Plan タブ、Targets タブ、Monitoring > Web Applications（Context Root、Open Sessions）、Testing タブ（テスト URL = コンテキストルート）。「Modules and Components」に EAR 内のモジュール（Web / EJB / JDBC モジュール）が表示される。

**D-2 デプロイ方式・リリース手順**

- ヒアリング: 誰が、どの手段で（コンソールのアップロード / `weblogic.Deployer` / WLST スクリプト / `autodeploy` ディレクトリ / 展開ディレクトリの上書き）、どの頻度で、どの成果物（EAR/WAR/展開ディレクトリ）をデプロイしているか。
- 証跡: リリース手順書、デプロイスクリプト（`grep -rl -E 'weblogic.Deployer|wlst|deploy\(' /home/* /opt/* 2>/dev/null`）、`$DOMAIN_HOME/servers/*/upload/` の内容（コンソールからアップロードした履歴）。
- ビルド側: `build.xml`/`pom.xml` に `weblogic.appc`、`wlcompile`、`wljspc`、`wldeploy` タスクがないか（H-9、H-12 と関連）。

**D-5 稼働中成果物の同一性**

```bash
# ① config.xml の source-path の成果物、② サーバ展開物（tmp/_WL_user）、③ リポジトリのビルド成果物 の 3 者を比較する
APP=<app name>
md5sum <source-path の EAR/WAR>
# 展開物側: WAR 内ファイルとの比較（展開ディレクトリを特定してから）
EXP=$(find $DOMAIN_HOME/servers/$SERVER_NAME/tmp/_WL_user/$APP -maxdepth 2 -type d -name war | head -1); echo $EXP
mkdir -p /tmp/cmp && cd /tmp/cmp && unzip -q -o <source-path の WAR> -d src_war
diff -rq src_war $EXP | grep -v 'jsp_servlet\|WEB-INF/lib' | head          # 記述子・クラス・JSP の差分
diff -q src_war/WEB-INF/web.xml $EXP/WEB-INF/web.xml; diff -q src_war/WEB-INF/weblogic.xml $EXP/WEB-INF/weblogic.xml
# クラスのビルド日時・MANIFEST
unzip -p <WAR> META-INF/MANIFEST.MF; unzip -l <WAR> | egrep 'WEB-INF/classes/.*\.class' | sort -k2 | tail -3   # 最新のビルド日時
```

#### 確認方法

- D-1: config.xml の `app-deployment` ⇔ コンソール Deployments（State=Active）⇔ 起動ログ `BEA-149059`/`BEA-149060`（モジュールの STATE_ACTIVE 遷移）⇔ `tmp/_WL_user` の展開物 の 4 者で、**稼働中アプリの一覧を確定**する。config.xml に定義があるが State が Prepared/Failed のもの、ターゲットが無いものは「移行対象外候補」として担当者に確認する。
- D-3: `plan.xml` に `variable-assignment` がある場合、**記述子（web.xml / weblogic.xml）の値がプランで上書きされている**。上書き後の値をコンソール（Deployments > [app] > Configuration）で確認し、G 章の結果は「記述子の値」と「プラン適用後の値」を分けて記録する。
- D-4: `library-ref`（weblogic.xml / weblogic-application.xml）で参照している共有ライブラリの実体（`$WL_HOME/common/deployable-libraries` 等の WAR/JAR）とバージョンを記録し、H-5 の同梱ライブラリ設計に転記する。
- D-5: 「稼働中の成果物 = リポジトリの特定リビジョンから再現できる」ことを確認する。再現できない場合（リポジトリより新しいクラスが稼働中、手修正された JSP が展開ディレクトリにある等）は、移行元ソースを確定するための課題として最優先で起票する。
- D-6: コンテキストルートは、スタンドアロン WAR では `weblogic.xml` の `context-root` > WAR ファイル名（拡張子除く）、EAR 内の WAR では `application.xml` の `<web><context-root>` が `weblogic.xml` より優先される。デプロイメントプランで上書きされている場合もあるため、コンソールの Deployments > [app] > Overview の Context Root と、実際の URL（アクセスログのパス、L-1）に一致することを確認する。

### 4.E JDBC データソース・JNDI（最重要）

#### 調査方法

**E-1〜E-4 データソース定義ファイル**

WebLogic のデータソースは `config.xml` の `<jdbc-system-resource>`（名前とターゲット）と、`config/jdbc/<名前>-jdbc.xml`（接続・プール・トランザクション設定）に分かれている。全ファイルをコピーして証跡とし、以下で要点を抽出する。

```bash
awk '/<jdbc-system-resource>/,/<\/jdbc-system-resource>/' $DOMAIN_HOME/config/config.xml   # <name>、<target>、<descriptor-file-name>
ls -la $DOMAIN_HOME/config/jdbc/
for f in $DOMAIN_HOME/config/jdbc/*-jdbc.xml; do
  echo "===== $f"
  # E-1 名前・JNDI 名・種別
  grep -E '<name>|<jndi-name>|<algorithm-type>|<data-source-list>|<use-xa-data-source-interface>|<fan-enabled>|<ons-node-list>' $f
  # E-2 接続先（パスワードは暗号化値のため出力してよい）
  grep -E '<url>|<driver-name>|<property>|<name>|<value>|<password-encrypted>' $f
  # E-3 プール設定
  awk '/<jdbc-connection-pool-params>/,/<\/jdbc-connection-pool-params>/' $f
  # E-4 トランザクション
  grep -E '<global-transactions-protocol>|<keep-xa-conn-till-tx-complete>|<xa-transaction-timeout>|<xa-set-transaction-timeout>|<xa-retry-duration-seconds>' $f
done
# EAR/WAR 内のアプリスコープ DS（E-8）
find $DOMAIN_HOME/servers/*/tmp/_WL_user -name '*-jdbc.xml' 2>/dev/null
```

記録する項目（6.4 の様式）:

| 区分 | 要素 | Tomcat 側の対応（参考） |
|---|---|---|
| 基本 | `name`、`jndi-name`（複数可）、`target`、種別（通常 / XA: `use-xa-data-source-interface` or XA ドライバ / Multi DS: `algorithm-type`+`data-source-list` / GridLink: `fan-enabled`） | `<Resource name="jdbc/xxx">`。Multi DS/GridLink は Tomcat に相当機能なし（RDS Multi-AZ では不要） |
| 接続 | `url`（`jdbc:oracle:thin:@host:1521:SID` か `@//host:1521/service`）、`driver-name`（`oracle.jdbc.OracleDriver` / `oracle.jdbc.xa.client.OracleXADataSource`）、`properties`（`user`、`oracle.net.CONNECT_TIMEOUT`、`oracle.jdbc.ReadTimeout`、`v$session.program` 等） | `url`、`driverClassName`、`username`、`connectionProperties` |
| プール | `initial-capacity`、`max-capacity`、`capacity-increment`、`shrink-frequency-seconds`、`inactive-connection-timeout-seconds`、`connection-reserve-timeout-seconds`、`highest-num-waiters`、`connection-creation-retry-frequency-seconds`、`login-delay-seconds` | `initialSize`、`maxTotal`/`maxActive`、`minIdle`/`maxIdle`、`maxWaitMillis`、`removeAbandonedTimeout` |
| 検査 | `test-connections-on-reserve`、`test-table-name`（`SQL SELECT 1 FROM DUAL` 等）、`test-frequency-seconds`、`seconds-to-trust-an-idle-pool-connection`、`remove-infected-connections-enabled` | `testOnBorrow`、`validationQuery`、`validationInterval`、`timeBetweenEvictionRunsMillis` |
| 文 | `statement-cache-size`、`statement-cache-type`、`statement-timeout` | `poolPreparedStatements`/`maxOpenPreparedStatements`（DBCP2）または ojdbc の暗黙キャッシュ |
| 初期化 | `init-sql`（`SQL ALTER SESSION SET ...` 等。NLS/タイムゾーン設定が入っていることがある） | `initSQL`（Tomcat JDBC Pool）/ `connectionInitSqls`（DBCP2） |
| TX | `global-transactions-protocol`（TwoPhaseCommit / LoggingLastResource / EmulateTwoPhaseCommit / OnePhaseCommit / None） | None/OnePhaseCommit 以外は JTA 前提 → H-4 で要否判断 |
| その他 | `pinned-to-thread`、`row-prefetch`、`stream-chunk-size`、`credential-mapping-enabled`、`identity-based-connection-pooling-enabled`、`wrap-types` | 該当機能はアプリ側で吸収 |

**E-5 JDBC ドライバの実体**

```bash
ls -la $WL_HOME/server/lib/ojdbc*.jar $WL_HOME/server/ext/jdbc/oracle/*/ojdbc*.jar 2>/dev/null   # WLS 同梱（10.3.4 は ojdbc6.jar 11.2.0.x）
ls -la $DOMAIN_HOME/lib/*.jar 2>/dev/null | grep -i -E 'ojdbc|oracle|jdbc'
tr '\0' '\n' < /proc/$PID/cmdline | tr ':' '\n' | grep -i -E 'ojdbc|oracle|jdbc'                  # クラスパス上の JDBC JAR（PRE_CLASSPATH での差し替え）
find $DOMAIN_HOME/servers/*/tmp/_WL_user -name 'ojdbc*.jar' 2>/dev/null                            # WEB-INF/lib 同梱
# バージョン確認
for j in <上記で見つかった ojdbc の JAR>; do echo "== $j"; unzip -p $j META-INF/MANIFEST.MF | egrep -i 'Implementation-Version|Specification-Version|Implementation-Title'; done
# 実際にロードされているドライバ（root または起動ユーザー）
ls -l /proc/$PID/fd 2>/dev/null | grep -i ojdbc
```

**E-6 JNDI ツリーとアプリ側参照**

- 管理コンソール: Environment > Servers > [server] > Configuration > General の「View JNDI Tree」リンク → 別ウィンドウにバインド一覧が表示される。`jdbc/`、`mail/`、`javax.transaction.UserTransaction`、`weblogic.*` 等をスクリーンショットに残す。
- 起動ログ: データソース作成メッセージ（`grep -h -i -E 'Connection Pool named|Data Source named|JNDI Name' $DOMAIN_HOME/servers/$SERVER_NAME/logs/$SERVER_NAME.log* | sort -u`）。
- 診断イメージ（要承認）: Diagnostics > Diagnostic Images > Capture Image で生成される zip の `JNDI.txt`、`JDBC.txt` に全バインドとプール状態が出力される。
- アプリ側参照（H-3 と共通）:

```bash
cd <WAR 展開ディレクトリ>
grep -n -A4 '<resource-ref>' WEB-INF/web.xml                                          # res-ref-name（java:comp/env/ 配下の論理名）
grep -n -A4 '<resource-description>' WEB-INF/weblogic.xml                              # res-ref-name → 実 JNDI 名のマッピング
grep -rn -E 'jndi-lookup|JndiObjectFactoryBean|jndi-name|jndiName|java:comp/env|resource-ref' WEB-INF/classes WEB-INF/*.xml WEB-INF/spring 2>/dev/null
grep -rn -E 'InitialContext|lookup\(' <ソースディレクトリ>/src --include='*.java'
```

**E-7 実績値**

- 管理コンソール: Services > Data Sources > [DS] > Monitoring > Statistics（Active Connections Current/High/Average Count、Current Capacity、Highest Num Available、Waiting For Connection High Count、Wait Seconds High Count、Leaked Connection Count、Failures To Reconnect Count、Prep Stmt Cache Hit/Miss Count、Connection Delay Time）。稼働開始日時（Servers > [server] > Monitoring > General の Activation Time）を併記する。
- WLST（付録 B）: `JDBCDataSourceRuntimeMBean` の同項目を一括出力する。
- 参考: 稼働時間が短い（直近に再起動された）場合、High Count はピークを反映していない可能性があるため、ヒアリングで過去の再起動日時を確認する。

#### 確認方法

- E-1/E-6: 「定義された DS（`*-jdbc.xml`）」「JNDI ツリーにバインドされた名前」「アプリが参照する名前（`resource-ref`/`weblogic.xml`/Spring 設定）」の 3 者を突合し、(a) 定義はあるがアプリが参照しない DS（移行不要候補）、(b) アプリが参照するが定義が無い名前（別の仕組み — アプリスコープ DS や直接接続 — の存在を示唆）の両方を洗い出す。
- E-2: JDBC URL のホストが `/etc/hosts`（A-1）で解決できること、`netstat` の ESTABLISHED（A-4）に同ホスト:1521 が存在すること。URL が SID 形式の場合、RDS はサービス名接続（`@//host:1521/ORCL`）となるため、接続文字列変更を設計課題に記録する。`jdbc:oracle:oci:` の場合は Oracle クライアント（A-7）が必要であり、Thin 化が必要。
- E-3: 設定値と実績値（E-7）を並べ、`max-capacity` に対する `Active Connections High Count` の比率と `Waiting For Connection High Count` の有無から、プールサイズ設計の根拠を作る。`init-sql` に NLS やセッション設定がある場合は、RDS 側のパラメータまたは Tomcat 側 `initSQL` へ引き継ぐ。
- E-4: `global-transactions-protocol` が `TwoPhaseCommit`/`LoggingLastResource`/`EmulateTwoPhaseCommit` の DS は JTA（グローバル TX）前提である。H-4 のアプリ側方式と突合し、「複数 DS にまたがる 1 トランザクションが実在するか」を確定する（実在しなければローカル TX へ移行できる）。
- E-5: 実際にロードされている ojdbc（クラスパス順序に依存: `PRE_CLASSPATH` > `$DOMAIN_HOME/lib` > WLS 同梱。`prefer-web-inf-classes=true` の場合は `WEB-INF/lib` が優先）を 1 つに確定する。同一名 JAR が複数箇所にある場合は要注意として記録する。

### 4.F その他 Java EE リソース（コンテナ提供機能）

#### 調査方法

```bash
CFG=$DOMAIN_HOME/config/config.xml
# F-1 JMS
grep -c -E '<jms-server>|<jms-system-resource>' $CFG
awk '/<jms-server>/,/<\/jms-server>/' $CFG; awk '/<jms-system-resource>/,/<\/jms-system-resource>/' $CFG
ls -la $DOMAIN_HOME/config/jms/ 2>/dev/null; cat $DOMAIN_HOME/config/jms/*.xml 2>/dev/null      # queue/topic/connection-factory/foreign-server
awk '/<saf-agent>/,/<\/saf-agent>/' $CFG; awk '/<messaging-bridge>/,/<\/messaging-bridge>/' $CFG
# F-2 メールセッション
awk '/<mail-session>/,/<\/mail-session>/' $CFG                          # <jndi-name>、<properties>（mail.smtp.host 等）
# F-3 外部 JNDI / RMI / IIOP
awk '/<foreign-jndi-provider>/,/<\/foreign-jndi-provider>/' $CFG
grep -E '<iiop-enabled>|<tunneling-enabled>|<default-iiop-user>' $CFG
# F-6 永続ストア
awk '/<file-store>/,/<\/file-store>/' $CFG; awk '/<jdbc-store>/,/<\/jdbc-store>/' $CFG
ls -la $DOMAIN_HOME/servers/*/data/store/* 2>/dev/null
# F-1/F-3/F-4/F-5/F-7 アプリ側（EAR/WAR 展開ディレクトリで）
cd <EAR/WAR 展開ディレクトリ>
find . -name 'ejb-jar.xml' -o -name 'weblogic-ejb-jar.xml' -o -name 'weblogic-webservices.xml' -o -name 'webservices.xml' -o -name '*-jms.xml' -o -name 'weblogic-ra.xml' | sort
grep -rl -E 'javax\.jms|javax\.ejb|javax\.mail|javax\.xml\.ws|javax\.xml\.rpc|javax\.persistence|commonj\.work|commonj\.timers|javax\.resource' WEB-INF/classes 2>/dev/null | head -50
grep -rn -E '@Stateless|@Stateful|@MessageDriven|@WebService|@PersistenceContext|@Resource' <ソース>/src --include='*.java' | head -50
grep -n -E 'work-manager|wl-dispatch-policy' WEB-INF/weblogic.xml
grep -n -A3 'commonj' WEB-INF/web.xml                                    # <resource-ref> で WorkManager/TimerManager を参照
```

管理コンソール: Services > Messaging（JMS Servers / JMS Modules / Foreign Servers / Bridges）、Services > Mail Sessions、Services > Persistent Stores、Services > Foreign JNDI Providers、Environment > Work Managers、Deployments > [app] > Modules and Components（EJB モジュール、Web サービスの有無）。

#### 確認方法

- F-1: JMS リソース定義が無く、アプリに `javax.jms` の参照も無ければ「JMS 未使用」と判定する。定義がある場合はキュー内の未処理メッセージ数（JMS Servers > Monitoring）と生産者/消費者（アプリ、ASTERIA、外部）を確認し、移行方式（ActiveMQ 等の導入、または DB テーブル/ファイル連携への置換）の設計課題として起票する。
- F-2: `mail-session` が定義されアプリが `mail/xxx` を JNDI 参照している場合、Tomcat の `<Resource type="javax.mail.Session">` と JavaMail JAR の同梱が必要。SMTP サーバのホスト（J-4）も記録する。
- F-3: EJB/RMI/T3/IIOP の利用は Tomcat では代替不可のため、利用箇所とその用途（他システムからの呼び出し、バッチからの `t3://` 参照）を H-12 と合わせて確定する。
- F-5: `commonj.work`/`commonj.timers`（Spring の `WorkManagerTaskExecutor`/`TimerManagerTaskScheduler`）の利用は Spring の `ThreadPoolTaskExecutor`/`ThreadPoolTaskScheduler` へ置換する前提で改修箇所を記録する。
- F-6: 永続ストアは JMS/JTA を使っていない限り移行不要。ファイルストアが存在しても中身が空（JTA tlog のみ）であれば「移行対象外」と記録する。

### 4.G Web アプリケーション記述子（WebLogic 固有設定）

#### 調査方法

対象は稼働中の成果物（D-5 で確定した EAR/WAR）の記述子。展開ディレクトリで実施する。

```bash
cd <WAR 展開ディレクトリ>
# G-1 web.xml
head -5 WEB-INF/web.xml                                                            # <web-app version="2.5"> 等（サーブレット仕様版）
grep -n -E '<servlet-name>|<servlet-class>|<url-pattern>|<filter-name>|<filter-class>|<listener-class>|<load-on-startup>' WEB-INF/web.xml
grep -n -A3 -E '<session-config>|<welcome-file-list>|<error-page>|<mime-mapping>|<jsp-config>|<login-config>|<security-constraint>|<security-role>|<env-entry>|<resource-ref>|<resource-env-ref>|<ejb-ref>|<context-param>|<init-param>' WEB-INF/web.xml
# G-2 weblogic.xml（全文を証跡に残した上で要素を棚卸し）
cat WEB-INF/weblogic.xml
grep -oE '<[a-z][a-z0-9-]*>' WEB-INF/weblogic.xml | sort | uniq -c | sort -rn
# G-3 EAR の場合
cat META-INF/application.xml META-INF/weblogic-application.xml 2>/dev/null
# G-5 文字コード
grep -n -A6 'charset-params' WEB-INF/weblogic.xml
grep -n -E 'webapp.encoding|input-charset|java-charset-name' META-INF/weblogic-application.xml WEB-INF/weblogic.xml 2>/dev/null
grep -rhoE 'pageEncoding="[^"]+"|contentType="[^"]+"' --include='*.jsp' --include='*.jspf' . | sort | uniq -c   # JSP のエンコーディング宣言の分布
grep -n -B2 -A6 -E 'CharacterEncodingFilter|encoding' WEB-INF/web.xml
tr '\0' '\n' < /proc/$PID/cmdline | grep -E 'file.encoding|sun.jnu.encoding'
# G-6 クラスローディング
grep -n -E 'prefer-web-inf-classes|prefer-application-packages|prefer-application-resources' WEB-INF/weblogic.xml META-INF/weblogic-application.xml 2>/dev/null
```

`weblogic.xml` で確認・記録する要素と読み替え先:

| weblogic.xml の要素 | 確認内容 | Tomcat 側の対応 |
|---|---|---|
| `context-root` | コンテキストルート | `<Context path>` / WAR 名 |
| `session-descriptor` | `timeout-secs`（WLS 既定 3600 秒）、`cookie-name`（既定 JSESSIONID）、`cookie-path`、`cookie-secure`、`cookie-http-only`、`cookie-max-age-secs`、`url-rewriting-enabled`、`persistent-store-type`（memory/file/jdbc/replicated）、`invalidation-interval-secs`、`id-length`、`sharing-enabled` | `web.xml session-config`（分単位。既定 30 分）、`<Context sessionCookieName ...>`、`<CookieProcessor>`、Manager |
| `jsp-descriptor` | `keepgenerated`、`precompile`、`page-check-seconds`、`backward-compatible`、`encoding`、`working-dir`、`print-nulls`、`strict-stale-check`、`compress-html-template` | Jasper の `web.xml` 初期化パラメータ（`development`、`checkInterval`、`keepgenerated`）。`backward-compatible`/`print-nulls` は互換性に注意 |
| `container-descriptor` | `prefer-web-inf-classes`、`prefer-application-packages`、`servlet-reload-check-secs`、`resource-reload-check-secs`、`filter-dispatched-requests-enabled`、`index-directory-enabled`、`show-archived-real-path-enabled`、`save-sessions-enabled`、`default-mime-type`、`client-cert-proxy-enabled`、`relogin-enabled`、`require-admin-traffic`、`container-initializer-enabled` | Tomcat は既定で Web アプリ優先（`prefer-web-inf-classes=true` 相当）。`show-archived-real-path-enabled` は `getRealPath()` の挙動（H-7） |
| `resource-description` / `resource-env-description` / `ejb-reference-description` | `res-ref-name` → `jndi-name` の対応 | `context.xml` の `<Resource>`/`<ResourceLink>` |
| `security-role-assignment` / `run-as-role-assignment` | ロール → プリンシパル（ユーザー/グループ） | Tomcat Realm のロール |
| `charset-params` | `input-charset`（リクエストのデコード文字コード）、`charset-mapping` | `Connector URIEncoding`、`CharacterEncodingFilter` |
| `library-ref` | 共有ライブラリ（名前、`specification-version`、`implementation-version`、`exact-match`） | WAR に同梱 |
| `work-manager` / `wl-dispatch-policy` | サーブレット単位のスレッド制約 | 対応なし（アプリ側またはコネクタで吸収） |
| `logging` | `log-filename`、`logging-enabled`、`rotation-type`、`file-count` | コンテキスト単位のログは Tomcat では JULI/AccessLogValve で設計 |
| `virtual-directory-mapping` / `url-match-map` | 静的リソースの別ディレクトリ配置、URL マッチング | Apache の `Alias`/`DocumentRoot` |
| `auth-filter`、`fast-swap`、`async-descriptor`、`coherence-cluster-ref`、`component-factory-class-name` | 特殊機能の利用有無 | 個別に代替設計 |

`weblogic-application.xml`（EAR）で確認する要素: `application-param`（`webapp.encoding.default`、`webapp.encoding.usevmdefault`、`webapp.getrealpath.dumb`）、`classloader-structure`、`listener`（`ApplicationLifecycleListener`）、`startup`/`shutdown`、`xml`（パーサファクトリ）、`jdbc-connection-pool`（旧形式のアプリスコープ DS）、`security`（`realm-name`）、`library-ref`、`prefer-application-packages`/`prefer-application-resources`、`session-descriptor`、`module` 上書き。

管理コンソール: Deployments > [app] > Configuration > General（Context Root、Session Timeout、JSP Page Check Seconds 等、**プラン適用後の値**）、Configuration > Security（Security Model、Roles/Policies）。

#### 確認方法

- G-1: `web.xml` の `resource-ref` と `weblogic.xml` の `resource-description` の対応が 1:1 であること（`resource-description` が無い場合、`res-ref-name` がそのままグローバル JNDI 名として解決される WLS 固有の挙動に依存している → H-3 で改修要）。
- G-2: `weblogic.xml` の全要素が上表のいずれかに分類され、「対応方針（Tomcat 設定へ読み替え / アプリ改修 / 不要）」が付与されていること。**未分類の要素を残さない**。
- G-4: セッションタイムアウトは `web.xml session-config`（分）と `weblogic.xml session-descriptor timeout-secs`（秒）の両方があり、**WLS では `web.xml` の設定が優先**される。どちらが有効かを D-3（プラン）も含めて確定し、実際のセッション有効時間をアプリ担当・運用担当と合意する。前段（Apache/ELB）がセッション Cookie 名（JSESSIONID）でスティッキーを行っている場合、Cookie 名変更は禁止事項として記録する。
- G-5: 「リクエストデコード（`input-charset`、`file.encoding`）」「JSP 出力（`pageEncoding`/`contentType`）」「DB 接続（NLS）」の 3 層で文字コードが一致していること。混在（Windows-31J と UTF-8）がある場合は、その箇所を全て列挙する。
- G-6: `prefer-web-inf-classes=false`（WLS 既定 = 親優先）で稼働している場合、Tomcat（子優先）へ移行すると `WEB-INF/lib` の古い JAR（Xerces、commons-logging、JDBC ドライバ等）が優先されて挙動が変わる可能性があるため、H-5 の JAR 一覧で「WLS 側と WAR 側で重複するライブラリ」を特定する。

### 4.H アプリケーション実装の WebLogic / Java 依存（ソース・バイナリ）

#### 調査方法

ソース（リポジトリ）と稼働バイナリ（D-5 で確定した WAR の展開物）の両方を対象にする。ソースが稼働物と一致しない可能性があるため、バイナリ側の検索を必ず行う。

**H-1、H-2、H-8、H-12 WebLogic 固有 API・設定の利用**

```bash
SRC=<ソースのルート>; WAR=<WAR 展開ディレクトリ>
# ソース: import 文の集計（何を、どこで使っているか）
grep -rn -E '^import (weblogic|commonj|com\.bea|com\.oracle\.weblogic)\.' $SRC --include='*.java' | sed 's/^\([^:]*\):[0-9]*:import \([^;]*\);.*/\2\t\1/' | sort | uniq > <証跡>
grep -rn -E '^import (weblogic|commonj|com\.bea)\.' $SRC --include='*.java' | sed 's/.*import \([^;]*\);.*/\1/' | sort | uniq -c | sort -rn   # API 別件数
# ソース: JSP・設定ファイル・プロパティ
grep -rln -i -E 'weblogic|commonj|com\.bea|t3://|t3s://|WLInitialContextFactory|wlfullclient|wlclient' $SRC --include='*.jsp' --include='*.jspf' --include='*.xml' --include='*.properties' --include='*.tld' --include='*.sh' --include='*.bat' --include='*.groovy' | sort
# H-2 Spring 設定の WebLogic 依存
grep -rn -E 'WebLogicJtaTransactionManager|WebLogicLoadTimeWeaver|WorkManagerTaskExecutor|TimerManagerTaskScheduler|JtaTransactionManager|load-time-weaver|jee:jndi-lookup|jee:local-slsb|jee:remote-slsb|JndiObjectFactoryBean|WebLogicMBeanServerFactoryBean|weblogic' $WAR/WEB-INF --include='*.xml' --include='*.properties'
# H-8 プロキシヘッダ・スキーム依存
grep -rn -E 'WL-Proxy-Client-IP|X-Forwarded-For|X-Forwarded-Proto|getRemoteAddr|getRemoteHost|isSecure\(\)|getScheme\(\)|getServerName\(\)|getServerPort\(\)' $SRC --include='*.java' --include='*.jsp'
# バイナリ: クラスファイルの定数プールから参照を検出（ソースと稼働物の差異を検出）
find $WAR/WEB-INF/classes -name '*.class' -print0 | xargs -0 grep -l -a -E 'weblogic/|commonj/|com/bea/' | sort
for j in $WAR/WEB-INF/lib/*.jar; do unzip -l "$j" | grep -q -E ' (weblogic|commonj|com/bea)/' && echo "WLS classes in: $j"; done
# H-12 バッチ・外部プログラム（RHEL 上の cron・スクリプト、Windows 側は別途ヒアリング）
# 対象はスクリプト・設定ファイルに限定し、深さ・サイズを制限する（/home や /opt が大きい場合の I/O 負荷対策）
find /home /opt /usr/local /etc/cron.d /var/spool/cron -maxdepth 4 -type f -size -2M \( -name '*.sh' -o -name '*.properties' -o -name '*.xml' -o -name '*.conf' -o -name '*.cfg' -o -name '*.py' -o -path '*/cron*' \) 2>/dev/null \
  | grep -v -E "^$MW_HOME|/tmp/_WL_user" | xargs -r grep -l -E 't3://|weblogic\.jar|wlfullclient|wlclient|WLInitialContextFactory|weblogic\.' 2>/dev/null | sort
```

**H-3、H-4 JNDI 参照方式・トランザクション管理方式**

```bash
grep -rn -E 'java:comp/env|java:comp/UserTransaction|jdbc/|mail/|jms/' $WAR/WEB-INF --include='*.xml' --include='*.properties' | grep -v -E '\.jar' | sort
grep -rn -E 'new InitialContext|\.lookup\(|UserTransaction|TransactionManager|@Transactional|<tx:|PlatformTransactionManager|DataSourceTransactionManager|HibernateTransactionManager|JpaTransactionManager|setAutoCommit|\.commit\(\)|\.rollback\(\)' $SRC --include='*.java' | sort > <証跡>
grep -rn -B2 -A6 -E 'TransactionManager' $WAR/WEB-INF --include='*.xml'
```

**H-5、H-6 ライブラリ依存・Java 11 影響**

`jdeps` は JDK 8 以降に同梱されており、RHEL 5.4 上には無い可能性が高い。**WAR を作業用端末（JDK 11 導入済み）へ持ち出して実施**する。

```bash
# WEB-INF/lib の一覧とバージョン（MANIFEST）
for j in $WAR/WEB-INF/lib/*.jar; do v=$(unzip -p "$j" META-INF/MANIFEST.MF 2>/dev/null | egrep -i '^(Implementation-Version|Bundle-Version|Specification-Version)' | head -1); echo "$(basename $j)	$v"; done | sort > <証跡>
ls -la $DOMAIN_HOME/lib/ $WL_HOME/server/lib/ | head -100                     # コンテナ側ライブラリ
# クラスファイルのコンパイルターゲット（major version: 49=1.5, 50=1.6, 51=1.7, 52=1.8）
find $WAR/WEB-INF/classes -name '*.class' | head -200 | xargs -I{} sh -c 'od -An -tu1 -j7 -N1 {}' | sort | uniq -c
# 以下は JDK 11 端末で実施
cd <WAR 展開ディレクトリ>
jdeps -R -verbose:package -cp 'WEB-INF/lib/*' WEB-INF/classes 2>/dev/null | grep -i 'not found' | sort -u > <証跡: 未解決パッケージ = コンテナ提供 or 欠落>
jdeps --jdk-internals -R -cp 'WEB-INF/lib/*' WEB-INF/classes WEB-INF/lib/*.jar 2>/dev/null > <証跡: JDK 内部 API 依存>
jdeps -R -verbose:package -cp 'WEB-INF/lib/*' WEB-INF/classes WEB-INF/lib/*.jar 2>/dev/null | grep -E 'javax\.xml\.bind|javax\.annotation|javax\.activation|javax\.xml\.ws|javax\.jws|javax\.transaction|org\.omg|javax\.rmi\.CORBA|sun\.|com\.sun\.' | sort -u > <証跡: JDK 11 で削除/非公開のパッケージ>
```

確認観点（Java 11）: Java 11 で JDK から削除された `java.xml.bind`（JAXB）、`java.xml.ws`（JAX-WS）、`java.activation`、`java.corba`、`java.transaction`（`javax.transaction.xa` は残る）、`javax.annotation`（JSR-250: `@PostConstruct`/`@Resource`）の利用有無。Spring 3.x（特に 3.0/3.1）は Java 8 以降を公式サポートしておらず、**Java 11 上でのクラススキャン（ASM）やプロキシ生成で問題が出る可能性が高い**ため、Spring の正確なバージョン（`spring-core-x.y.z.jar`）と Spring のバージョンアップ（4.3 系または 5 系）の要否を設計課題として起票する。あわせて、Hibernate/MyBatis(iBatis)/log4j/commons-* 等の主要ライブラリのバージョンを記録する。

**H-7 ファイルシステム依存**

```bash
grep -rhoE '(/[A-Za-z0-9_.-]+){2,}' $WAR/WEB-INF/classes $WAR/WEB-INF/*.xml $WAR/WEB-INF/*.properties 2>/dev/null | grep -v -E '^/(WEB-INF|META-INF|org/|com/|java/|javax/|net/|http)' | sort | uniq -c | sort -rn | head -100   # 設定ファイル中の絶対パス
grep -rn -E 'getRealPath|File\.separator|new File\(|FileOutputStream|FileWriter|java\.io\.tmpdir|user\.dir|user\.home|createTempFile' $SRC --include='*.java' | sort > <証跡>
grep -rn -E 'MultipartResolver|CommonsMultipartResolver|maxUploadSize|uploadTempDir' $WAR/WEB-INF --include='*.xml'
ls -l /proc/$PID/fd 2>/dev/null | awk '{print $NF}' | grep '^/' | grep -v -E "^$MW_HOME|^$JAVA_HOME|/tmp/_WL_user|\.jar$" | sort -u   # 実際に開いているファイル（ログ・データファイル）
```

**H-9 JSP**

```bash
find $WAR -name '*.jsp' -o -name '*.jspf' -o -name '*.tag' | wc -l
grep -rhoE '<%@ *taglib[^>]*uri="[^"]+"' --include='*.jsp' --include='*.jspf' $WAR | sed 's/.*uri="//; s/"//' | sort | uniq -c | sort -rn   # 使用タグライブラリ
find $WAR -name '*.tld' | sort; ls $WAR/WEB-INF/lib | egrep -i 'jstl|standard|taglibs|struts|tiles|displaytag'
ls -la $DOMAIN_HOME/servers/$SERVER_NAME/tmp/_WL_user/<app>/*/jsp_servlet/ 2>/dev/null | head   # WLS 側で生成された JSP クラス（プリコンパイル有無）
grep -n -A8 'jsp-descriptor' $WAR/WEB-INF/weblogic.xml
# WLS の JSP コンパイラで通るが Jasper で失敗しやすい記述の検出（例）
grep -rn -E '<%@ *page[^>]*import=[^>]*import=' --include='*.jsp' $WAR | head           # 同一ディレクティブ内の重複属性
grep -rln -E '<jsp:include[^>]*flush=|<%@ *include' --include='*.jsp' $WAR | wc -l
grep -rhoE '<%@ *page[^>]*isELIgnored="[^"]+"' --include='*.jsp' $WAR | sort | uniq -c
grep -rln '\$\{' --include='*.jsp' $WAR | wc -l; grep -rln '#{' --include='*.jsp' $WAR | wc -l      # EL 利用と JSP 2.1 の #{} 衝突
```

**H-10 ロギング実装**

```bash
ls $WAR/WEB-INF/lib | egrep -i 'log4j|logback|slf4j|commons-logging|jcl|jul'
find $WAR/WEB-INF/classes -maxdepth 1 -name 'log4j*' -o -name 'logback*' -o -name 'logging.properties' -o -name 'commons-logging.properties'
cat $WAR/WEB-INF/classes/log4j.properties $WAR/WEB-INF/classes/log4j.xml 2>/dev/null | egrep -i 'File=|MaxFileSize|MaxBackupIndex|DatePattern|ConversionPattern|Threshold|rootLogger|log4j.logger'
tr '\0' '\n' < /proc/$PID/cmdline | grep -i -E 'log4j|logging|Log4jLoggingEnabled'
grep -E '<log4j-logging-enabled>|<redirect-stdout-to-server-log-enabled>|<redirect-stderr-to-server-log-enabled>' $DOMAIN_HOME/config/config.xml
ls -la $DOMAIN_HOME/servers/$SERVER_NAME/logs/                                     # アプリログが WLS ログディレクトリに混在していないか
```

**H-11 スケジューラ・非同期処理**

```bash
ls $WAR/WEB-INF/lib | egrep -i 'quartz|cron'
grep -rn -E 'quartz|SchedulerFactoryBean|CronTrigger|@Scheduled|@Async|task:scheduler|task:executor|new Thread\(|ExecutorService|Executors\.|java\.util\.Timer|TimerTask|ServletContextListener' $SRC --include='*.java' $WAR/WEB-INF --include='*.xml' --include='*.properties' | sort > <証跡>
grep -rn -E 'org\.quartz\.(jobStore|threadPool|scheduler)' $WAR/WEB-INF --include='*.properties'   # JobStore（RAM/JDBC）、クラスタ設定
```

#### 確認方法

- H-1/H-2: ソース側の検出結果とバイナリ側（クラスファイル・JAR）の検出結果が一致すること。バイナリにのみ存在する参照は「ソースが稼働物と一致していない」ことを意味するため D-5 に差し戻す。検出した全 API について、用途と代替方針（例: `WebLogicJtaTransactionManager` → `DataSourceTransactionManager`、`commonj.work` → `ThreadPoolTaskExecutor`、`weblogic.servlet.security.ServletAuthentication` → Tomcat Realm + `HttpServletRequest#login`）を 6.6 の様式に記録する。
- H-3: JNDI 名の参照形式を「`java:comp/env/` 経由 + `resource-ref` あり」「グローバル名直接（WLS 固有）」に分類し、後者の件数を改修見積りの根拠とする。
- H-4: 「JTA を使うトランザクション定義があるか」「1 トランザクションで複数 DS を更新する処理があるか」の 2 点を確定する（E-4 と突合）。両方とも No であればローカル TX（`DataSourceTransactionManager`）へ移行する。
- H-5: `jdeps` の未解決パッケージのうち `javax.servlet`/`javax.servlet.jsp`/`javax.el` は Tomcat が提供する。それ以外（`javax.mail`、`javax.jms`、`javax.ejb`、`javax.transaction`、`javax.xml.bind`、`javax.annotation`、`weblogic.*`、`commonj.*`）は「Tomcat が提供しない = 同梱または改修が必要」として一覧化する。
- H-6: コンパイルターゲット（major version）が 52（Java 8）以下であること、`--jdk-internals` の検出が無いこと（あれば代替 API を記録）。Spring バージョンによる Java 11 対応可否を判定し、必要な場合は「Spring バージョンアップ」を移行スコープに含めるかどうかの判断材料をまとめる。
- H-7: 絶対パスは全て「用途」「読み書き」「所有者」「ローテーション/削除の仕組み」「RHEL 9 での配置先」を付与して一覧化する。NFS/CIFS（A-2）や ASTERIA/Windows との共有（J-2、J-3）と関連付ける。
- H-9: 移行時に **全 JSP を Jasper でプリコンパイル**（`org.apache.jasper.JspC`）してコンパイルエラーを洗い出す計画を立て、本調査ではその対象数と WLS 固有設定（`backward-compatible` 等）の有無を確定する。
- H-10: ログ出力先が WLS の `logs/` 配下や絶対パスの場合、Tomcat 移行後の出力先とローテーション方式（log4j 自身 / logrotate）を K-1 で設計する。`redirect-stdout-to-server-log-enabled=true` の場合、`System.out` が WLS サーバログに混在している点を移行後の挙動差（`catalina.out` へ出力）として記録する。

### 4.I 前段 Web サーバ・ロードバランサ

#### 調査方法

**I-1 前段構成の特定**

```bash
netstat -tlnp 2>/dev/null | egrep ':80 |:443 |:7001 |:7002 '                  # 80/443 を誰が待ち受けているか
ps -ef | grep '[h]ttpd'; rpm -q httpd mod_ssl
# アクセスログの接続元 IP の分布（全て同一 IP → 前段プロキシ/ELB 経由、多様 → 直接アクセス）
awk '{print $1}' $DOMAIN_HOME/servers/$SERVER_NAME/logs/access.log | sort | uniq -c | sort -rn | head -10
grep -E '<weblogic-plugin-enabled>|<frontend-host>|<frontend-http-port>|<frontend-https-port>' $DOMAIN_HOME/config/config.xml
# 外部から見た経路（作業端末から。DNS 名 → ELB か EC2 か）
nslookup <サービスの FQDN>; curl -sI https://<サービスの FQDN>/<context>/ | egrep -i '^(Server|Set-Cookie|Location|X-|Via|Strict)'
```

**I-2 Apache 設定（同居している場合。別サーバの場合はそのサーバで実施）**

```bash
httpd -v; httpd -M 2>/dev/null; httpd -S 2>/dev/null                            # 版、ロード済みモジュール、vhost 一覧
ls -laR /etc/httpd/ | head -100; cat /etc/httpd/conf/httpd.conf; cat /etc/httpd/conf.d/*.conf
find /etc/httpd /usr/lib64/httpd /usr/lib/httpd -name 'mod_wl*' 2>/dev/null   # WebLogic プラグイン
grep -rn -i -E 'WebLogicHost|WebLogicPort|WebLogicCluster|MatchExpression|WLProxySSL|WLProxySSLPassThrough|WLIOTimeoutSecs|WLLogFile|WLCookieName|PathTrim|PathPrepend|Idempotent|ConnectTimeoutSecs|WLSocketTimeoutSecs|KeepAliveEnabled|KeepAliveSecs|WLExcludePathOrMimeType|DynamicServerList|Debug' /etc/httpd/ 2>/dev/null
grep -rn -i -E 'ProxyPass|ProxyPassReverse|RewriteRule|RewriteCond|Alias|DocumentRoot|Listen|ServerName|KeepAlive|Timeout|MaxClients|ServerLimit|StartServers|LogFormat|CustomLog|ErrorLog|SSLCertificateFile|SSLProtocol|SSLCipherSuite|Allow from|Deny from|AuthType|Require|Header|Deflate|ExpiresByType' /etc/httpd/ 2>/dev/null
ls -la /var/log/httpd/; tail -3 /var/log/httpd/access_log
```

**I-3 ELB / セキュリティグループ / DNS（AWS 管理コンソールまたは CLI。インフラ担当へ依頼可）**

```bash
aws elb describe-load-balancers --region ap-northeast-1                          # Classic ELB（リスナー、ヘルスチェック、証明書、SG）
aws elb describe-load-balancer-attributes --load-balancer-name <name>            # アイドルタイムアウト、アクセスログ
aws elb describe-load-balancer-policies --load-balancer-name <name>              # スティッキー（Cookie 名）
aws elbv2 describe-load-balancers; aws elbv2 describe-target-groups               # ALB の場合
aws ec2 describe-security-groups --group-ids <sg-id>
aws ec2 describe-instances --instance-ids <id> --query 'Reservations[].Instances[].[InstanceType,PrivateIpAddress,SecurityGroups]'
aws route53 list-resource-record-sets --hosted-zone-id <zone>
```

#### 確認方法

- I-1: 「クライアント → (ELB) → (Apache) → WebLogic」の経路と、各区間のプロトコル（HTTP/HTTPS）・ポート・SSL 終端箇所を図に起こし、関係者（インフラ担当）に確認する。`weblogic-plugin-enabled`、アクセスログの接続元 IP、`mod_wl` の有無の 3 点で整合を取る。
- I-2: `mod_wl` の全ディレクティブを一覧化し、Tomcat 移行後の `mod_proxy_http`/`mod_proxy_ajp` 設定への読み替え（`WebLogicHost/Port` → `ProxyPass`、`WLIOTimeoutSecs` → `timeout`、`WLProxySSL` → `RequestHeader set X-Forwarded-Proto`、`PathTrim/PathPrepend` → パス変換、`WLExcludePathOrMimeType` → 静的配信）を 7 章の対応表で確認する。Apache が RHEL 5 の 2.2 系であれば、Apache 2.4 での設定書式変更（`Require` 等）も記録する。
- I-3: ヘルスチェックパス（WebLogic 側の URL）、アイドルタイムアウト（Tomcat の `connectionTimeout`/`keepAliveTimeout` との関係）、スティッキー Cookie 名を記録する。

### 4.J 外部連携

#### 調査方法

**J-1 Oracle DB**

```bash
# 接続先ホスト・ポート・SID/サービス名（E-2 の URL）と実接続
netstat -anp 2>/dev/null | grep ':1521' | awk '{print $5}' | sort | uniq -c
grep -h '<url>' $DOMAIN_HOME/config/jdbc/*-jdbc.xml
# tnsnames（OCI 利用時のみ）
cat $TNS_ADMIN/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora 2>/dev/null
```

DB 側（DBA へ依頼。RDS 移行設計の前提）: `SELECT * FROM v$version;`、`SELECT * FROM nls_database_parameters WHERE parameter IN ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET','NLS_LANGUAGE','NLS_TERRITORY');`、`SELECT username, account_status, default_tablespace FROM dba_users WHERE oracle_maintained='N' OR username IN (...);`（11g では `oracle_maintained` 列は無いため対象ユーザーを指定）、DB リンク（`dba_db_links`）、`v$session` の `program`/`machine`（AP サーバからのセッション数の実績: `SELECT machine, program, COUNT(*) FROM v$session GROUP BY machine, program;`）。

**J-2 ASTERIA、J-3 Windows Server、J-4 その他**

```bash
# 接続先の傾向（一定時間おきに数回取得して差分を見る）
netstat -anp 2>/dev/null | grep ESTABLISHED | awk '{print $5}' | sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn
# CIFS/NFS/FTP/SMTP/HTTP クライアントの痕跡
mount | egrep -i 'cifs|nfs|smb'; rpm -qa | egrep -i 'samba|cifs|nfs-utils|ftp|lftp|sendmail|postfix'
grep -rn -E 'smb://|cifs|ftp://|sftp|smtp|mail\.smtp\.host|http://|https://' $WAR/WEB-INF/classes/*.properties $WAR/WEB-INF/*.xml 2>/dev/null | grep -v -E 'xmlns|schemaLocation|w3\.org|springframework|sun\.com|java\.sun|oracle\.com/weblogic'   # 外部 URL・ホスト
grep -rn -E 'asteria|ASTERIA|flow' $WAR/WEB-INF/classes/*.properties $WAR/WEB-INF/*.xml 2>/dev/null
ps -ef | grep -i '[a]steria'; find /opt /home /usr/local -maxdepth 3 -iname '*asteria*' 2>/dev/null
cat /etc/hosts                                                                   # Windows サーバ・DB・ASTERIA の名前解決
```

ヒアリング項目（アプリ担当・ASTERIA 担当・Windows サーバ担当）:

- ASTERIA のフローが本アプリと連携する方式（HTTP 呼び出し / 共有ディレクトリへのファイル配置 / DB テーブル経由 / JMS）、方向（どちらが起点か）、頻度、ファイル形式・文字コード、エラー時の扱い
- Windows Server 2008 R2 上で稼働しているもの（Oracle 11g か、ASTERIA か、バッチか）と AP サーバとの通信（SMB 共有、FTP、RDP、スケジュールタスク）
- SMTP サーバ、外部 API、LDAP、プロキシ、NTP の接続先

#### 確認方法

- J-1: JDBC URL（E-2）、`netstat` の実接続先、`/etc/hosts`、DBA からの `v$session` 情報が同一の DB を指すこと。SID とサービス名、キャラクタセット（`NLS_CHARACTERSET`: JA16SJISTILDE / AL32UTF8 等）を確定し、RDS 19c 側のパラメータ設計へ引き渡す。
- J-2/J-3: 連携方式を「方向 × 手段 × 頻度 × データ形式」の表にし、両側（AP サーバ側の設定・スクリプトと ASTERIA/Windows 側の設定）の証跡で裏付ける。ファイル連携の場合は共有ディレクトリのパス・権限（H-7、A-2）と一致すること。
- J-4: 全ての外部接続先について「ホスト名/IP、ポート、プロトコル、方向、用途、移行後の接続先」を一覧化し、RHEL 9 のセキュリティグループ・NACL 設計へ引き渡す。

### 4.K 運用・ログ・監視

#### 調査方法

```bash
# K-1 ログ一覧（WLS 側 + アプリ側 + httpd + OS）
ls -la $DOMAIN_HOME/servers/*/logs/ $DOMAIN_HOME/*.log /var/log/httpd/ 2>/dev/null
find $DOMAIN_HOME -maxdepth 4 -name '*.log*' -not -path '*/tmp/*' -exec ls -la {} \; 2>/dev/null | sort -k9 | head -100
ls -l /proc/$PID/fd 2>/dev/null | awk '{print $NF}' | grep -i -E '\.log|\.out|\.txt|\.csv' | sort -u   # 実際に書き込み中のログ
head -3 $DOMAIN_HOME/servers/$SERVER_NAME/logs/access.log                       # 形式（common / extended の #Fields 行）
# K-5 定期ジョブ（A-5 の cron に加え、WLS/アプリ内スケジューラ）
cat /var/spool/cron/* 2>/dev/null; ls -la /etc/cron.d/
```

ヒアリング（運用担当）:

- K-2 監視: 監視ツール、監視項目（プロセス、ポート、URL 応答、ログキーワード、ディスク、JVM）、閾値、通知先、監視除外時間
- K-3 バックアップ: 対象（ドメインディレクトリ、成果物、ログ、DB）、方式（AMI/スナップショット/ファイル）、頻度、世代、リストア手順
- K-4 手順書: 起動停止手順、リリース手順、障害時の一次対応（再起動判断、ログ採取）、パスワード変更（DB パスワード変更時に WebLogic 側で行っている操作）、証明書更新手順、ログ保管・削除手順 — **手順書の一覧と所在を記録し、コピーを入手する**
- K-5 ジョブ: cron 以外のスケジューラ（JP1/Hinemos、Windows タスク、ASTERIA スケジュール）から AP サーバへ実行されるもの

#### 確認方法

- K-1: 「設定上のログ（C-7、H-10、I-2）」と「実際に存在するログファイル」と「運用担当が参照・保管しているログ」の 3 者が一致し、各ログに保管期間と用途（監査、障害解析、集計）が付与されていること。
- K-2〜K-4: 手順書の記載と実機の状態（A-5 の自動起動、B-5 の起動スクリプト、D-2 のデプロイ方式）が一致していること。不一致は「手順書が古い」か「運用が手順書から逸脱している」かを確認し、Tomcat 版の手順書作成時の注意点として記録する。

### 4.L 実績値・性能ベースライン

#### 調査方法

**L-1 アクセス実績（アクセスログ集計。WLS の common 形式を想定。extended 形式の場合は `#Fields:` 行に従って列を読み替える）**

```bash
LOGS="$DOMAIN_HOME/servers/$SERVER_NAME/logs/access.log*"
cat $LOGS | wc -l
cat $LOGS | awk '{print substr($4,2,11)}' | sort | uniq -c | sort -k2 | tail -60                 # 日別件数
cat $LOGS | awk '{print substr($4,2,17)}' | sort | uniq -c | sort -rn | head -20                  # 分単位ピーク（YYYY:HH:MM）
cat $LOGS | awk '{print substr($4,14,2)}' | sort | uniq -c                                        # 時間帯分布
cat $LOGS | awk '{print $7}' | sed 's/?.*//' | sort | uniq -c | sort -rn | head -50               # URL 別件数
cat $LOGS | awk '{print $9}' | sort | uniq -c | sort -rn                                          # ステータスコード分布
cat $LOGS | awk '$9>=500 {print $7}' | sed 's/?.*//' | sort | uniq -c | sort -rn | head -20         # 5xx の URL
cat $LOGS | awk '{print $6}' | tr -d '"' | sort | uniq -c                                        # メソッド分布（POST の比率）
# extended 形式で time-taken を出力している場合の応答時間分布（列番号は #Fields 行で確認）
grep -h '^#Fields' $LOGS | sort -u
```

**L-2 JVM 実績**

```bash
tr '\0' '\n' < /proc/$PID/cmdline | grep -E 'Xms|Xmx|Xmn|PermSize|Xloggc|verbose:gc|UseParallel|UseConcMark|UseG1|Xgc'
ls -la $DOMAIN_HOME/servers/$SERVER_NAME/logs/*gc* $DOMAIN_HOME/*gc* 2>/dev/null                # GC ログ（有れば全量を証跡に）
grep -c 'Full GC' <GC ログ>; grep 'Full GC' <GC ログ> | tail -20
ps -o pid,rss,vsz,nlwp,etime,args -p $PID                                                        # RSS、スレッド数（nlwp）
$JAVA_HOME/bin/jstat -gcutil $PID 1000 10 2>/dev/null                                            # HotSpot のヒープ使用率（要承認: 低負荷）
$JAVA_HOME/bin/jstack $PID > <証跡> 2>/dev/null                                                  # スレッドダンプ（要承認）。JRockit は jrcmd $PID print_threads
grep -c 'ExecuteThread' <スレッドダンプ>; grep -A1 'ExecuteThread' <スレッドダンプ> | grep -c 'weblogic.work.ExecuteThread.waitForRequest'   # 総数と待機数
```

管理コンソール: Servers > [server] > Monitoring > Performance（Heap Size Current/Max、Heap Free、GC 情報）、Monitoring > General（Activation Time、Uptime、Open Sockets Current Count、Java Version）。

**L-3 スレッドプール・セッション実績**

管理コンソール: Servers > [server] > Monitoring > Threads（Execute Thread Total Count、Execute Thread Idle Count、Hogging Thread Count、Standby Thread Count、Queue Length、Pending User Request Count、Completed Request Count、Throughput）。Deployments > [app] > Monitoring > Web Applications（Open Sessions Current Count、Open Sessions High Count、Sessions Opened Total Count）、Monitoring > Servlets（Invocation Total Count、Execution Time Average/High/Total）。WLST（付録 B）で同項目を一括取得する。

**L-4 JDBC・JTA 実績**: E-7 と、Servers > [server] > Monitoring > JTA（Transaction Total Count、Committed、Rolled Back、Rolled Back Timeout、Abandoned、Active）。

**L-5 OS リソース実績**

```bash
ls /var/log/sa/                                                                                  # sysstat（あれば直近 1 ヶ月）
for f in /var/log/sa/sa[0-9]*; do echo "== $f"; sar -u -f $f | tail -3; sar -r -f $f | tail -2; sar -q -f $f | tail -2; done 2>/dev/null
vmstat 5 6; uptime
```

AWS: CloudWatch の EC2 メトリクス（CPUUtilization、NetworkIn/Out、DiskRead/Write）を直近 1〜3 ヶ月分、日次最大値でエクスポート（インフラ担当へ依頼）。

**L-6 エラー・警告の傾向**

```bash
SL="$DOMAIN_HOME/servers/$SERVER_NAME/logs/$SERVER_NAME.log*"
cat $SL | grep -oE '<BEA-[0-9]+>' | sort | uniq -c | sort -rn | head -40                          # メッセージ ID 別件数
cat $SL | grep -E '<Error>|<Critical>|<Emergency>' | grep -oE '<BEA-[0-9]+>' | sort | uniq -c | sort -rn
cat $SL | grep -c 'BEA-000337'; cat $SL | grep 'BEA-000337' | tail -5                            # Stuck Thread
cat $SL | grep -i -c 'OutOfMemoryError'; cat $SL | grep -i 'OutOfMemoryError' | tail -3
cat $SL | grep -E 'BEA-001112|BEA-001129|BEA-001153|BEA-000802|BEA-101020|BEA-000449' | grep -oE '<BEA-[0-9]+>' | sort | uniq -c   # JDBC テスト失敗/接続失敗、サーブレット例外、ソケット
grep -c 'BEA-000365' $SL; grep 'BEA-000365' $SL | grep -oE '^####<[^>]+>' | tail -10               # 再起動履歴（RUNNING 遷移の日時）
```

#### 確認方法

- L-1: 集計対象期間（開始日〜終了日、ローテーションで欠落した期間）を明記する。日次件数と分単位ピークは、性能テストの負荷条件（同時ユーザー数・スループット）として設計書に転記する。
- L-2/L-3: 「ヒープ最大に対する使用率のピーク」「Execute Thread Total Count のピークと Hogging の有無」「Open Sessions High Count」を、稼働開始日時とともに記録する。Tomcat の `-Xmx`、`maxThreads`（既定 200）、セッション設計の根拠とする。
- L-6: 頻出するエラー・警告は「既知の事象として引き継ぐもの」「移行で解消すべきもの」に分類し、課題一覧（6.8）に転記する。再起動履歴から定期再起動の運用有無を確認する（K-4）。

### 4.M 環境差分（dev / qa / honban）

#### 調査方法

3 環境で同一の手順（付録 A のスクリプト）により証跡を取得したのち、以下で差分を抽出する。比較前にホスト名・IP・暗号化値をマスクして「本質的な差分」だけを残す。

```bash
# 例: honban と qa の比較（証跡ディレクトリ survey/<env>/C_domain/config を想定）
mask() { sed -E 's/\{AES\}[A-Za-z0-9+\/=]+/{AES}***/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/IP.IP.IP.IP/g' "$1"; }
for f in config/config.xml config/jdbc/*-jdbc.xml bin/setDomainEnv.sh; do
  echo "===== $f"; diff <(mask survey/honban/C_domain/$f) <(mask survey/qa/C_domain/$f)
done
diff survey/honban/G_descriptor/weblogic.xml survey/qa/G_descriptor/weblogic.xml
diff survey/honban/D_deploy/plan.xml survey/qa/D_deploy/plan.xml 2>/dev/null
diff survey/honban/I_httpd/httpd.conf survey/qa/I_httpd/httpd.conf 2>/dev/null
diff <(sort survey/honban/A_os/rpm.txt) <(sort survey/qa/A_os/rpm.txt)
diff survey/honban/B_install/bsu_patches.txt survey/qa/B_install/bsu_patches.txt
diff survey/honban/H_libs/webinf_lib.txt survey/qa/H_libs/webinf_lib.txt                     # 成果物のライブラリ差（環境で成果物が違う場合）
```

#### 確認方法

- M-1: 差分は全て「環境固有値（意図的: ホスト・ポート・接続先・パス・サイズ）」「構成ドリフト（意図せず: パッチ差、パラメータ差、手修正）」のいずれかに分類し、後者は担当者に是正要否を確認する。
- M-2: 環境固有値は 6.7 の様式にまとめ、Tomcat 移行後に環境ごとに切り替えるパラメータ（`context.xml`、`setenv.sh`、Apache 設定、アプリのプロパティ）の設計インプットとする。認証情報は値ではなく「所在（誰が管理し、どこに保管されているか）」を記録する。
- M-3: サーバ台数・Apache 有無・監視有無等の構成差は、移行後の 3 環境の構成を「揃える」か「差分を維持する」かの判断材料として、設計方針への申し送りとする。

---
## 5. 調査結果の確認方法（クロスチェック・完了判定）

### 5.1 クロスチェック表

各調査結果は、次の表の突合を行い一致した時点で「確認済」とする。不一致の場合は「実際に動いている値（③）」を正としたうえで、不一致の理由を記録する。

| 対象 | 情報源 A | 情報源 B | 情報源 C | 情報源 D | 不一致時の典型的な原因 |
|---|---|---|---|---|---|
| WebLogic 版・パッチ | `.product.properties` / `registry.xml` | 起動ログ `BEA-141107` | コンソール Monitoring > General | BSU 出力 | 複数インストールの混在、パッチ適用後の未再起動 |
| JDK | `setDomainEnv.sh` / `commEnv.sh` | `readlink /proc/$PID/exe` | 起動ログ `BEA-000377` | コンソール Monitoring > General（Java Version） | 独自ラッパーで `JAVA_HOME` 上書き、`<server-start>` の Java Home |
| リッスンポート | `config.xml` `<listen-port>` | `netstat -tlnp` | 起動ログ `BEA-002613` | コンソール Servers 一覧 | `-Dweblogic.ListenPort`、ネットワークチャネル、管理ポート |
| JVM 引数 | `setDomainEnv.sh`（`MEM_ARGS`、`JAVA_OPTIONS`） | `/proc/$PID/cmdline` | `<server-start>`（NM 起動時） | — | ラッパースクリプト、`USER_MEM_ARGS`、環境変数 |
| デプロイ済みアプリ | `config.xml` `<app-deployment>` | コンソール Deployments（State） | 起動ログ `BEA-149059/149060` | `tmp/_WL_user` 展開物 | Prepared 状態、未ターゲット、旧アプリの残骸 |
| 稼働成果物 | `<source-path>` の EAR/WAR（md5） | `tmp/_WL_user` 展開物 | リポジトリのビルド成果物 | MANIFEST/クラス日時 | 展開ディレクトリの手修正、リポジトリ未反映 |
| データソース | `config/jdbc/*-jdbc.xml` | コンソール Data Sources | JNDI ツリー / 起動ログ（プール作成） | アプリの `resource-ref`/Spring 設定 | 未使用 DS、アプリスコープ DS、直接接続 |
| JDBC ドライバ | `WL_HOME/server/lib` | クラスパス（`cmdline`） | `/proc/$PID/fd` の JAR | `WEB-INF/lib` | `PRE_CLASSPATH` 差し替え、`prefer-web-inf-classes` |
| セッション設定 | `web.xml` `session-config` | `weblogic.xml` `session-descriptor` | `plan.xml` | コンソール Deployments > Configuration / 実 Cookie（`curl -I`） | 記述子間の優先順位、プラン上書き |
| 文字コード | `weblogic.xml charset-params` | `-Dfile.encoding` / `LANG` | JSP `pageEncoding` | DB `NLS_CHARACTERSET` | 層ごとの不一致（実は変換に依存） |
| ログ | `config.xml` `<log>`/`<web-server-log>` | `ls logs/` | logrotate / cron | 運用手順書 | 独自ローテーション、stdout 肥大化 |
| 前段経路 | `httpd.conf` / `mod_wl` | `netstat` 80/443 | ELB 設定 | アクセスログ接続元 IP、`weblogic-plugin-enabled` | 未使用の Apache 設定、経路変更の未反映 |
| 外部接続先 | 設定ファイルの URL/ホスト | `netstat` ESTABLISHED | `/etc/hosts` / SG | ヒアリング | 廃止済み連携、テスト用設定の残存 |
| 環境差分 | honban 証跡 | qa 証跡 | dev 証跡 | パラメータシート/手順書 | 構成ドリフト |

### 5.2 起動ログによる検証

サーバログ（`$DOMAIN_HOME/servers/<server>/logs/<server>.log`、ローテーション済みは `.log0000N`）から**最後の起動シーケンス**（最後の `BEA-000365` RUNNING 遷移までの区間）を抽出し、以下のメッセージで構成を裏付ける。抽出例:

```bash
SL=$DOMAIN_HOME/servers/$SERVER_NAME/logs/$SERVER_NAME.log
START=$(grep -n 'BEA-000377\|Starting WebLogic Server' $SL | tail -1 | cut -d: -f1); END=$(grep -n 'BEA-000365.*RUNNING' $SL | tail -1 | cut -d: -f1)
sed -n "${START},${END}p" $SL > <証跡: 起動シーケンス>
grep -oE '<BEA-[0-9]+>' <証跡: 起動シーケンス> | sort | uniq -c | sort -rn
```

| メッセージ ID（例） | 内容 | 裏付けられる項目 |
|---|---|---|
| BEA-000377 | Starting WebLogic Server with `<JVM 名・版>` | B-1 |
| BEA-141107 | Version: WebLogic Server 10.3.4.0 ... | B-2 |
| BEA-090082 | Security initializing using security realm `<realm>` | C-9 |
| BEA-090169 / BEA-090171 | Loading trusted certificates / identity certificate from `<keystore>` | C-8 |
| BEA-002611 | Hostname `<host>`, maps to multiple IP addresses | A-1、C-2 |
| BEA-002613 | Channel "Default" is now listening on `<ip>:<port>` for protocols ... | C-2、A-4 |
| BEA-000331 | Started WebLogic Admin Server `<name>` for domain `<domain>` running in Production Mode | C-1 |
| BEA-000365 | Server state changed to STANDBY / STARTING / ADMIN / RUNNING | 起動完了の判定、再起動履歴 |
| BEA-149059 / BEA-149060 | Module `<module>` of application `<app>` is transitioning ... / successfully transitioned to STATE_ACTIVE | D-1 |
| （JDBC）Creating Connection Pool named ... / Data Source named ... | データソース作成（ID は環境により異なるためキーワードで検索） | E-1、E-6 |
| BEA-000287 | Invoking startup class `<class>` | C-12 |
| BEA-149205 / BEA-149265 | Failed to initialize the application ... / Failure occurred in the execution of deployment request | デプロイ失敗の有無 |
| BEA-002616 | Failed to listen on channel ... （port in use） | ポート競合の有無 |
| Spring: `Initializing Spring root WebApplicationContext`、`FrameworkServlet '<name>': initialization completed` | Spring コンテキストの起動と `contextConfigLocation` | H-2、G-1 |

※ メッセージ ID の対応は代表例であり、実ログの文言で確認する。ID が異なっていても文言で判断できるようにキーワード検索を併用する。

### 5.3 環境差分の確認

4.M の手順に従い、honban を基準に qa/dev の差分を抽出し、差分ごとに「意図的な環境固有値」か「構成ドリフト」かを分類する。分類結果は 6.7 に記録し、構成ドリフトは担当者確認のうえで移行後の統一方針を決める。

### 5.4 稼働中成果物とソースの同一性確認

D-5 の手順に従い、「`<source-path>` の成果物 = `tmp/_WL_user` の展開物 = リポジトリの特定リビジョンのビルド成果物」を md5 と `diff -rq` で確認する。**この確認が取れない場合、移行元ソースが確定できないため、最優先課題として起票する。**

### 5.5 ヒアリング項目一覧

調査担当者が実機・ファイルから確定できない事項は、以下の相手にヒアリングして確定する。ヒアリング結果は日時・相手・回答を記録し、証跡と同等に扱う。

| 対象 | ヒアリング項目 | 関連 No |
|---|---|---|
| 運用担当 | 起動停止手順、自動起動、定期再起動、監視項目・閾値、バックアップ、ログ保管、証明書・パスワード更新手順、過去の障害と対処 | A-5、A-6、B-5、K-1〜K-5、L-6 |
| アプリ担当 | 稼働中バージョンとリポジトリの対応、デプロイ手順、外部連携の仕様、ファイル入出力、バッチ、既知の WebLogic 依存、JSP の特殊な記述、文字コードの前提、最大アップロードサイズ | D-2、D-5、H-*、J-2、J-3、C-6 |
| DBA | DB のホスト・SID/サービス名・キャラクタセット、ユーザー一覧、AP からのセッション数、DB リンク、init SQL の意図 | E-2、E-3、J-1 |
| インフラ担当（AWS） | ELB/SG/DNS/証明書、インスタンスタイプ、CloudWatch 実績、Windows サーバの役割 | A-2、I-3、J-3、L-5 |
| ASTERIA 担当 | フロー一覧のうち本アプリと連携するもの、方式、方向、スケジュール | J-2 |
| セキュリティ担当 | コンテナ認証の利用、ユーザー管理の方針、SSL 終端箇所、監査ログ要件 | C-8、C-9 |

### 5.6 完了判定基準（Definition of Done）

以下を全て満たした時点で現行調査を完了とし、レビューを実施する。

1. 3 章の全項目（重要度 ◎・○）について、6.1 の様式に「結果」「証跡ファイル名」「判定（確認済 / 該当なし / 不明）」が記入されている。「該当なし」は根拠（検索結果が 0 件、定義が存在しない等）が示されている
2. 3 環境（dev/qa/honban）すべてで証跡が取得され、honban との差分が 6.7 に整理されている
3. 5.1 のクロスチェック表の全行について突合が完了し、不一致は理由が記録されている
4. 5.4 の同一性確認が完了し、移行元ソース（リポジトリのリビジョン/タグ）が確定している
5. WebLogic 依存箇所一覧（6.6）が「件数」「用途」「代替方針候補」つきで完成し、未分類の依存が残っていない
6. `weblogic.xml`/`weblogic-application.xml` の全要素に対応方針が付与されている（G-2 の確認方法）
7. データソース一覧（6.4）が JNDI 名・アプリ側参照・実績値まで埋まっている
8. 「不明」項目は担当者・期限つきで課題一覧（6.8）に登録され、移行設計を進めるうえでのブロッカーか否かが明示されている
9. 運用担当・アプリ担当によるレビューを実施し、指摘が反映されている

---

## 6. 調査結果の記録様式（テンプレート）

調査結果は `WebLogic現行環境調査結果一覧_ver1.md`（または Excel）として、以下の様式で記録する。環境ごとに列を設けるか、環境ごとにシートを分ける。

### 6.1 調査結果一覧

| No | 調査項目 | 環境 | 調査結果（要約） | 証跡ファイル | 判定 | 移行への影響 | 対応方針候補 | 備考 |
|---|---|---|---|---|---|---|---|---|
| A-1 | OS 基本情報 | honban | RHEL 5.4、TZ=Asia/Tokyo、LANG=ja_JP.UTF-8 | honban_A-1_os.txt | 確認済 | — | — | |
| B-1 | JDK | honban | | | | | | |
| … | | | | | | | | |

判定: 確認済（クロスチェック一致）/ 要確認（不一致あり・理由記載）/ 該当なし（根拠記載）/ 不明（課題登録）

### 6.2 サーバ・ポート一覧

| 環境 | ホスト | サーバ名 | 種別（Admin/Managed） | リッスンアドレス | HTTP ポート | SSL ポート | 管理ポート | チャネル（プロトコル/ポート） | 起動方式（手動/init/NM） | 起動ユーザー | 備考 |
|---|---|---|---|---|---|---|---|---|---|---|---|

### 6.3 デプロイ済みアプリケーション一覧

| 環境 | アプリ名 | 種別（EAR/WAR） | コンテキストルート | ターゲット | ソースパス | ステージング | デプロイ順序 | 状態 | プラン有無 | 共有ライブラリ参照 | 成果物 md5 | リポジトリ対応（タグ/リビジョン） | 備考 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

### 6.4 JDBC データソース一覧

| 環境 | DS 名 | JNDI 名 | ターゲット | 種別 | URL | ドライバ | DB ユーザー | 初期/最大/増分 | テスト設定 | タイムアウト（reserve/inactive） | 文キャッシュ | init SQL | TX プロトコル | アプリ側参照名 | 実績（Active High / Waiting High / Leaked / Failures） | 備考 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

### 6.5 JVM 起動パラメータ一覧

| 環境 | サーバ名 | 引数/プロパティ | 値 | 定義箇所（setDomainEnv / server-start / ラッパー） | 分類（メモリ/GC/エンコード/TZ/WLS 固有/アプリ/SSL/その他） | Tomcat での扱い（引継ぎ/読み替え/不要） | 備考 |
|---|---|---|---|---|---|---|---|

### 6.6 WebLogic 依存箇所一覧

| No | 種別（Java API / Spring 設定 / 記述子 / JSP / スクリプト / ライブラリ） | 依存内容（クラス・要素名） | ファイル（パス:行） | 用途 | 件数 | 代替方針候補 | 改修規模（大/中/小） | 備考 |
|---|---|---|---|---|---|---|---|---|

### 6.7 環境固有値・環境差分一覧

| 項目 | dev | qa | honban | 定義箇所 | 分類（環境固有値 / 構成ドリフト） | Tomcat 移行後の定義箇所（案） | 備考 |
|---|---|---|---|---|---|---|---|

### 6.8 不明点・課題一覧

| No | 内容 | 関連調査 No | 影響（ブロッカー / 設計判断 / 参考） | 確認先 | 担当 | 期限 | 状態 | 結果 |
|---|---|---|---|---|---|---|---|---|

### 6.9 外部接続先一覧

| 環境 | 接続先（ホスト/IP） | ポート | プロトコル | 方向 | 用途 | 定義箇所 | 移行後の接続先（案） | 備考 |
|---|---|---|---|---|---|---|---|---|

### 6.10 ログ一覧

| 環境 | ログ種別 | パス | 形式 | ローテーション（方式/サイズ/世代） | 保管期間 | 出力元（WLS/アプリ/httpd/OS） | 参照者・用途 | 移行後の出力先（案） |
|---|---|---|---|---|---|---|---|---|

---

## 7. 調査結果の移行設計への反映（WebLogic → Tomcat 対応観点）

調査結果が移行設計のどこに反映されるかを示す。ver1 では観点の整理にとどめ、具体的な設計値は調査結果確定後に設計書へ記載する。

| WebLogic 側（調査 No） | Tomcat 9 / Apache 側の設計対象 | 設計上の注意点 |
|---|---|---|
| JDBC データソース（E-1〜E-7） | `conf/context.xml` または `META-INF/context.xml` の `<Resource type="javax.sql.DataSource">`（Tomcat JDBC Pool / DBCP2）、`WEB-INF/web.xml` の `resource-ref` | JNDI 名は `java:comp/env/jdbc/xxx`。ドライバは `$CATALINA_BASE/lib` に配置（ojdbc8/ojdbc10 19c）。RDS はサービス名接続 |
| Multi Data Source / GridLink（E-1） | 対応なし | RDS Multi-AZ のフェイルオーバー時は再接続（`testOnBorrow` + `validationQuery`）で対応 |
| JTA / XA（C-10、E-4、H-4） | Spring `DataSourceTransactionManager`（ローカル TX）。真に 2PC が必要なら Atomikos/Narayana 等を組み込み | 複数 DS 更新の実在確認が前提 |
| JNDI グローバル名直接参照（H-3） | `java:comp/env` 経由に統一 | `resource-ref` の追加、Spring `jee:jndi-lookup` の `resource-ref="true"` |
| `weblogic.xml session-descriptor`（G-4） | `web.xml session-config`、`<Context sessionCookieName sessionCookiePath ...>`、`<CookieProcessor>`、Manager | タイムアウト単位（秒→分）、Cookie 名は前段スティッキーと整合 |
| `charset-params`（G-5） | `Connector URIEncoding`（既定 UTF-8）、`useBodyEncodingForURI`、`CharacterEncodingFilter`（`forceEncoding`） | Windows-31J 系の場合は明示設定必須 |
| `max-post-size` / `post-timeout-secs`（C-6） | `Connector maxPostSize`（既定 2MB）、`maxParameterCount`、`connectionTimeout` | WLS 既定は無制限のため、明示的に拡大しないと大きな POST が失敗する |
| スレッドプール・Stuck Thread（C-5、L-3） | `Connector maxThreads`（既定 200）、`acceptCount`、`minSpareThreads`、`StuckThreadDetectionValve` | 実績の Execute Thread ピークから決定 |
| `weblogic-plugin-enabled` / `WL-Proxy-Client-IP`（C-6、H-8） | `RemoteIpValve` / `RemoteIpFilter`（`X-Forwarded-For`、`X-Forwarded-Proto`）、Apache `RequestHeader set X-Forwarded-Proto` | `getRemoteAddr()`/`isSecure()` の結果を維持 |
| サーバログ・stdout（C-7、H-10） | `conf/logging.properties`（JULI）、`catalina.out` のローテーション（logrotate / `CATALINA_OUT`）、アプリ log4j 設定 | `System.out` の出力先変更、WLS のロギングブリッジ廃止 |
| アクセスログ（C-7、L-1） | `AccessLogValve`（`pattern`、`rotatable`、`fileDateFormat`）または Apache のアクセスログに集約 | 集計用途に必要な項目（応答時間 `%D` 等）を決める |
| 共有ライブラリ `library-ref`（D-4）、ドメイン lib（B-3）、WLS 同梱ライブラリ（H-5） | `WEB-INF/lib` に同梱、または `$CATALINA_BASE/lib` | 同梱漏れ・重複（`prefer-web-inf-classes` 差）に注意 |
| 起動クラス・`ApplicationLifecycleListener`（C-12、G-3） | `ServletContextListener`、Spring の `SmartLifecycle`/`@PostConstruct` | 初期化順序 |
| Work Manager / CommonJ（F-5） | Spring `ThreadPoolTaskExecutor` / `ThreadPoolTaskScheduler` | 同時実行数の上限を明示 |
| JMS（F-1） | ActiveMQ 等の外部 MOM、または連携方式の変更 | 別途方式設計 |
| Mail Session（F-2） | `<Resource type="javax.mail.Session">` + JavaMail JAR | — |
| EJB / RMI / T3（F-3、H-12） | 対応なし。バッチは DataSource を直接生成（Spring スタンドアロン）または REST 化 | 影響範囲の確定が必須 |
| セキュリティレルム（C-9） | Tomcat `Realm`（JDBCRealm / DataSourceRealm / JNDIRealm）、または Spring Security 化 | コンテナ認証を使っている場合のみ |
| SSL / キーストア（C-8） | Apache `mod_ssl`（証明書は ELB/ACM 終端も検討） | Tomcat は HTTP（AJP）のみで受ける構成が一般的 |
| `mod_wl`（I-2） | `mod_proxy_http` または `mod_proxy_ajp`（`ProxyPass`、`ProxyPassReverse`、`timeout`、`keepalive`、`ProxyPreserveHost`） | `PathTrim`/`PathPrepend`、`WLExcludePathOrMimeType` の読み替え |
| Node Manager / 起動スクリプト（B-4、B-5） | systemd ユニット（`Type=forking`/`simple`、`User`、`LimitNOFILE`、`Environment`）、`bin/setenv.sh` | `ulimit`、`umask`、環境変数の引継ぎ |
| JVM 引数（C-4、L-2） | `CATALINA_OPTS`（`-Xms`/`-Xmx`、GC、`-Dfile.encoding`、`-Duser.timezone`、`-Djava.security.egd`、アプリ `-D`） | `-XX:MaxPermSize` は Java 8 以降で廃止、JRockit 固有引数は削除。`-Dweblogic.*` は全て不要 |
| デプロイ方式（D-2、D-3） | WAR を `webapps/` に配置（`autoDeploy`/`unpackWARs`）、または Manager アプリ。環境固有値は `context.xml`/`setenv.sh`/外部プロパティへ | `plan.xml` の上書き項目を外出しパラメータに変換 |
| JSP（H-9、G-2 `jsp-descriptor`） | Jasper（`web.xml` の JspServlet 初期化パラメータ）、JspC によるプリコンパイル | WLS の緩い解釈に依存した JSP の修正 |
| 監視・WLDF・SNMP（C-11、K-2） | JMX（`-Dcom.sun.management.jmxremote`）、Tomcat Manager status、CloudWatch エージェント | 監視項目の再定義 |

---
## 8. 付録

### 付録 A. 一括収集スクリプト（wls_survey.sh）

4 章のコマンドのうち、参照のみで完結するものを一括実行し、証跡を 1 ディレクトリ（および tar.gz）にまとめるスクリプト。RHEL 5.x（bash 3.2）で動作するよう、bash 4 以降の機能は使用していない。

- 実行ユーザー: WebLogic 起動ユーザー（`/proc/<pid>/` の参照のため）。A-4/A-5 の一部（`netstat -p` のプロセス名、他ユーザーの crontab）は root で実行した場合のみ取得できる
- 変更操作は含まない（`cp`/`ls`/`cat`/`grep`/`find`/`netstat`/`ps`/`unzip -l` のみ）。`jstack`/`jmap`/診断イメージ取得は含めていない
- `bsu.sh` と `java weblogic.version` は JVM を起動するため数十秒かかる。honban では実行時間帯に注意する
- 成果物（EAR/WAR）を `D_artifacts/` にコピーするため、成果物が大きい場合は `/tmp` の空き容量を確認する
- 実行前に内容をレビューし、環境に合わせて `find` の対象範囲などを調整する

```bash
#!/bin/bash
#===============================================================================
# wls_survey.sh : WebLogic 現行環境 情報収集スクリプト（参照のみ）
#   対象   : RHEL 5.x / WebLogic Server 10.3.x / bash 3.2
#   使い方 : ENV=honban ./wls_survey.sh
#            自動判定できない場合は DOMAIN_HOME / WL_HOME / SERVER_NAME / PID を環境変数で指定
#   出力   : /tmp/wls_survey_<ENV>_<host>_<日時>/ と同名の .tar.gz
#===============================================================================
ENV=${ENV:-unknown}
TS=$(date +%Y%m%d_%H%M%S)
OUT=/tmp/wls_survey_${ENV}_$(hostname -s)_${TS}
mkdir -p "$OUT" || exit 1
exec > >(tee -a "$OUT/00_survey.log") 2>&1
echo "### wls_survey.sh start: $(date) user=$(id -un) host=$(hostname) ENV=$ENV"

# run <出力ファイル名> : コマンドはヒアドキュメント（標準入力）で受け取り、子 bash で実行する
run() {
  local f="$OUT/$1"
  { echo "### $(date '+%F %T') [$(id -un)@$(hostname -s)] $1"; echo; bash -s; } > "$f" 2>&1
  echo "  -> $1 ($(wc -l < "$f") lines)"
}

#--- 0. WebLogic プロセスと各ホームの特定 --------------------------------------
PIDS=$(pgrep -f 'weblogic.Server' | tr '\n' ' ')
PID=${PID:-$(echo $PIDS | awk '{print $1}')}
if [ -n "$PID" ]; then
  DOMAIN_HOME=${DOMAIN_HOME:-$(readlink /proc/$PID/cwd 2>/dev/null)}
  WL_HOME=${WL_HOME:-$(tr '\0' '\n' < /proc/$PID/cmdline 2>/dev/null | grep -m1 '^-Dplatform.home=' | sed 's#^-Dplatform.home=##')}
  [ -z "$WL_HOME" ] && WL_HOME=$(tr '\0' '\n' < /proc/$PID/cmdline 2>/dev/null | grep -m1 '^-Dwls.home=' | sed 's#^-Dwls.home=##; s#/server/*$##')
  SERVER_NAME=${SERVER_NAME:-$(tr '\0' '\n' < /proc/$PID/cmdline 2>/dev/null | grep -m1 '^-Dweblogic.Name=' | sed 's#^-Dweblogic.Name=##')}
  JAVA_EXE=$(readlink /proc/$PID/exe 2>/dev/null)
  [ -n "$JAVA_EXE" ] && JAVA_HOME=${JAVA_HOME:-$(dirname $(dirname "$JAVA_EXE"))}
else
  echo "WARN: weblogic.Server process not found. DOMAIN_HOME/WL_HOME/JAVA_HOME must be given by environment variables."
fi
MW_HOME=${MW_HOME:-$(dirname "$WL_HOME")}
export OUT ENV PIDS PID DOMAIN_HOME WL_HOME MW_HOME SERVER_NAME JAVA_HOME
echo "PIDS=$PIDS PID=$PID DOMAIN_HOME=$DOMAIN_HOME WL_HOME=$WL_HOME MW_HOME=$MW_HOME SERVER_NAME=$SERVER_NAME JAVA_HOME=$JAVA_HOME" | tee "$OUT/00_vars.txt"

#--- A. OS ---------------------------------------------------------------------
run A-1_os.txt <<'EOS'
cat /etc/redhat-release; uname -a; hostname; hostname -f; echo
cat /etc/hosts; echo; cat /etc/resolv.conf; echo; cat /etc/sysconfig/network; echo
date; cat /etc/sysconfig/clock; ls -l /etc/localtime; cat /etc/sysconfig/i18n; locale
EOS
run A-2_resources.txt <<'EOS'
grep -c processor /proc/cpuinfo; grep 'model name' /proc/cpuinfo | sort -u
free -m; swapon -s; df -hP; mount; cat /etc/fstab
echo "instance-type: $(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-type)"
du -sh "$MW_HOME" "$DOMAIN_HOME" 2>/dev/null
EOS
run A-3_users_limits.txt <<'EOS'
id; egrep -v 'nologin|/bin/false' /etc/passwd; egrep 'weblogic|wls|oracle|bea|apache|tomcat' /etc/group
cat /etc/security/limits.conf; ls /etc/security/limits.d 2>/dev/null; ulimit -a
[ -n "$PID" ] && cat /proc/$PID/limits
sysctl -a 2>/dev/null | egrep 'ip_local_port_range|tcp_keepalive|somaxconn|tcp_max_syn_backlog|file-max|shmmax|swappiness'
EOS
run A-4_network.txt <<'EOS'
/sbin/ifconfig -a; netstat -rn; echo
netstat -tlnp 2>/dev/null | sort -k4; echo
netstat -anp 2>/dev/null | grep ESTABLISHED | awk '{print $4, $5, $7}' | sort | uniq -c | sort -rn | head -100; echo
/sbin/iptables -L -n 2>/dev/null; cat /etc/sysconfig/iptables 2>/dev/null; getenforce 2>/dev/null
EOS
run A-5_startup_cron_logrotate.txt <<'EOS'
chkconfig --list 2>/dev/null; ls -la /etc/init.d/; echo; cat /etc/rc.local; ls -la /etc/rc3.d/ /etc/rc5.d/
echo '--- init scripts mentioning weblogic/java/httpd'; grep -l -i -E 'weblogic|startWebLogic|nodemanager|httpd|java' /etc/init.d/* /etc/rc.local 2>/dev/null
echo '--- crontab (all users; requires root)'
for u in $(cut -d: -f1 /etc/passwd); do c=$(crontab -l -u $u 2>/dev/null); [ -n "$c" ] && { echo "=== $u"; echo "$c"; }; done
echo '--- crontab (current user)'; crontab -l 2>/dev/null
cat /etc/crontab; ls -la /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; cat /etc/cron.d/* 2>/dev/null
echo '--- logrotate'; cat /etc/logrotate.conf; cat /etc/logrotate.d/* 2>/dev/null
EOS
run A-6_agents.txt <<'EOS'
ps -ef | egrep -i 'zabbix|nagios|nrpe|hinemos|jp1|amazon-ssm|cloudwatch|awslogs|fluentd|td-agent|splunk|datadog|snmpd|newrelic|netbackup|arcserve' | grep -v egrep
chkconfig --list 2>/dev/null | egrep -i 'zabbix|nagios|nrpe|hinemos|jp1|ssm|awslogs|snmpd'
EOS
run A-7_packages.txt <<'EOS'
rpm -qa | sort
EOS
run A-7_tools.txt <<'EOS'
rpm -qa | egrep -i 'httpd|mod_ssl|oracle|instantclient|java|jdk|jre|openssl|sysstat|lsof|unzip'
which httpd sqlplus tnsping lsof unzip 2>/dev/null; env | egrep 'ORACLE|TNS_ADMIN|LD_LIBRARY_PATH'
find / -xdev -maxdepth 4 -name tnsnames.ora 2>/dev/null
EOS
run A_profile.txt <<'EOS'
cat /etc/profile; cat /etc/profile.d/*.sh 2>/dev/null; cat ~/.bash_profile ~/.bashrc 2>/dev/null
EOS

#--- B/C. プロセス・JVM・インストール ---------------------------------------------
run C-4_ps_java.txt <<'EOS'
ps -eo user,pid,ppid,lstart,etime,rss,vsz,nlwp,pcpu,pmem,args | grep -i '[j]ava'
EOS
for p in $PIDS; do
  export p
  run C-4_proc_${p}.txt <<'EOS'
echo "--- cmdline"; tr '\0' '\n' < /proc/$p/cmdline; echo
echo "--- cwd/exe"; readlink /proc/$p/cwd; readlink /proc/$p/exe; echo
echo "--- environ"; tr '\0' '\n' < /proc/$p/environ 2>/dev/null | sort; echo
echo "--- limits"; cat /proc/$p/limits; echo
echo "--- open files (regular)"; ls -l /proc/$p/fd 2>/dev/null | awk '{print $NF}' | grep '^/' | sort | uniq -c | sort -rn
EOS
done
run B-1_java.txt <<'EOS'
"$JAVA_HOME/bin/java" -version 2>&1; ls -la "$MW_HOME" | egrep -i 'jdk|jrockit'
egrep -n 'JAVA_HOME|JAVA_VENDOR|VM_TYPE' "$WL_HOME/common/bin/commEnv.sh"
egrep -n 'JAVA_HOME|JAVA_VENDOR|BEA_JAVA_HOME|SUN_JAVA_HOME' "$DOMAIN_HOME/bin/setDomainEnv.sh"
rpm -qa | egrep -i 'jdk|java'; ls -la /usr/java /usr/lib/jvm 2>/dev/null
EOS
run B-2_wls_version.txt <<'EOS'
cat "$WL_HOME/.product.properties"; echo
grep -i 'name=\|version=' "$MW_HOME/registry.xml" | head -40; echo
cat "$MW_HOME/domain-registry.xml"; echo; cat ~/bea/beahomelist 2>/dev/null
ls -la "$MW_HOME" "$WL_HOME"; ls -la "$MW_HOME"/patch_wls*/patch_jars 2>/dev/null
EOS
run B-2_wls_version_cmd.txt <<'EOS'
. "$WL_HOME/server/bin/setWLSEnv.sh" > /dev/null 2>&1; java weblogic.version -verbose
EOS
run B-2_bsu_patches.txt <<'EOS'
cd "$MW_HOME/utils/bsu" && ./bsu.sh -prod_dir="$WL_HOME" -status=applied -verbose -view
EOS
run B-3_domain_tree.txt <<'EOS'
ls -la "$DOMAIN_HOME"; echo
find "$DOMAIN_HOME" -maxdepth 3 -not -path '*/tmp/*' -not -path '*/logs/*' | sort; echo
du -sh "$DOMAIN_HOME"/* "$DOMAIN_HOME"/servers/* 2>/dev/null; echo
ls -la "$DOMAIN_HOME/lib" "$DOMAIN_HOME/autodeploy" "$DOMAIN_HOME"/servers/*/security 2>/dev/null
for j in "$DOMAIN_HOME"/lib/*.jar; do [ -f "$j" ] && { echo "== $j"; unzip -p "$j" META-INF/MANIFEST.MF 2>/dev/null | egrep -i 'Implementation-Version|Bundle-Version|Specification-Version'; }; done
EOS
run B-4_nodemanager.txt <<'EOS'
ps -ef | grep -i '[N]odeManager'; netstat -tlnp 2>/dev/null | grep 5556
cat "$WL_HOME/common/nodemanager/nodemanager.properties" "$WL_HOME/common/nodemanager/nodemanager.domains" 2>/dev/null
EOS
run B-5_setDomainEnv_effective.txt <<'EOS'
( . "$DOMAIN_HOME/bin/setDomainEnv.sh" > /dev/null 2>&1; env | egrep '^(JAVA_HOME|JAVA_VENDOR|MEM_ARGS|USER_MEM_ARGS|JAVA_OPTIONS|JAVA_PROPERTIES|EXTRA_JAVA_PROPERTIES|CLASSPATH|PRE_CLASSPATH|POST_CLASSPATH|PRODUCTION_MODE|WL_HOME|DOMAIN_HOME|LD_LIBRARY_PATH|PATH|WLS_REDIRECT_LOG)=' )
echo '--- wrapper scripts'; grep -l -E 'startWebLogic|weblogic\.Server|startManagedWebLogic|stopWebLogic' /etc/init.d/* /etc/rc.local /home/*/*.sh /opt/*/*.sh /usr/local/bin/* 2>/dev/null
EOS

#--- C. ドメイン設定（ファイルコピー） -------------------------------------------
mkdir -p "$OUT/C_domain"
cp -rp "$DOMAIN_HOME/config" "$OUT/C_domain/" 2>/dev/null
cp -rp "$DOMAIN_HOME/bin"    "$OUT/C_domain/" 2>/dev/null
cp -p  "$DOMAIN_HOME"/*.sh "$DOMAIN_HOME"/*.xml "$DOMAIN_HOME"/*.properties "$DOMAIN_HOME"/*.ini "$OUT/C_domain/" 2>/dev/null
cp -rp "$WL_HOME/common/nodemanager" "$OUT/C_domain/nodemanager" 2>/dev/null
find "$OUT/C_domain" -name 'boot.properties' -exec rm -f {} \; 2>/dev/null      # 資格情報ファイルは収集しない
echo "  -> C_domain/ (copied config/, bin/, nodemanager/)"
run C-1_config_elements.txt <<'EOS'
grep -oE '^[[:space:]]*<[a-z][a-z0-9-]*>' "$DOMAIN_HOME/config/config.xml" | sed 's/^[[:space:]]*//' | sort | uniq -c | sort -rn
EOS
run C-8_ssl.txt <<'EOS'
grep -E '<key-stores>|key-store-file-name|<server-private-key-alias>|<hostname-verifier>|<hostname-verification-ignored>|<jsse-enabled>|<two-way-ssl-enabled>|<client-certificate-enforced>' "$DOMAIN_HOME/config/config.xml"
ls -la "$WL_HOME"/server/lib/*.jks "$JAVA_HOME"/jre/lib/security/cacerts "$JAVA_HOME"/lib/security/cacerts 2>/dev/null
EOS
run C-9_security_files.txt <<'EOS'
ls -la "$DOMAIN_HOME/security" "$DOMAIN_HOME"/servers/*/data/ldap/ldapfiles 2>/dev/null
EOS

#--- D/G/H. デプロイ・成果物・記述子 ---------------------------------------------
run D-1_deployments.txt <<'EOS'
awk '/<app-deployment>/,/<\/app-deployment>/' "$DOMAIN_HOME/config/config.xml"; echo
awk '/<library>/,/<\/library>/' "$DOMAIN_HOME/config/config.xml"; echo
ls -la "$WL_HOME/common/deployable-libraries" "$DOMAIN_HOME/config/deployments" 2>/dev/null
echo '--- plans'; grep -E '<plan-path>|<plan-dir>' "$DOMAIN_HOME/config/config.xml"
find "$DOMAIN_HOME" -maxdepth 6 -name plan.xml -not -path '*/tmp/*' 2>/dev/null | while read f; do echo "=== $f"; cat "$f"; done
echo '--- server tmp/stage/upload'; ls -la "$DOMAIN_HOME"/servers/*/stage "$DOMAIN_HOME"/servers/*/upload "$DOMAIN_HOME"/servers/*/tmp/_WL_user 2>/dev/null
find "$DOMAIN_HOME"/servers/*/tmp/_WL_user -maxdepth 4 -type d 2>/dev/null | sort
EOS
mkdir -p "$OUT/D_artifacts" "$OUT/G_descriptors"
for sp in $(sed -n 's#.*<source-path>\(.*\)</source-path>.*#\1#p' "$DOMAIN_HOME/config/config.xml"); do
  case "$sp" in /*) p="$sp";; *) p="$DOMAIN_HOME/$sp";; esac
  n=$(basename "$p"); echo "--- source-path: $p"
  { echo "### $p"; ls -la "$p"; } >> "$OUT/D-5_artifacts.txt" 2>&1
  if [ -f "$p" ]; then
    md5sum "$p" >> "$OUT/D-5_artifacts.txt"; unzip -l "$p" >> "$OUT/D-5_artifacts.txt" 2>&1
    unzip -l "$p" | awk '{print $4}' | grep '^WEB-INF/lib/' > "$OUT/H-5_webinf_lib_$n.txt"
    cp -p "$p" "$OUT/D_artifacts/" 2>/dev/null
    mkdir -p "$OUT/G_descriptors/$n"
    unzip -o -q "$p" 'WEB-INF/web.xml' 'WEB-INF/weblogic.xml' 'META-INF/*' 'WEB-INF/*.xml' 'WEB-INF/classes/*.properties' 'WEB-INF/classes/*.xml' 'WEB-INF/spring/*' -d "$OUT/G_descriptors/$n" 2>/dev/null
    for w in "$OUT/G_descriptors/$n"/*.war; do   # EAR 内の WAR
      [ -f "$w" ] && unzip -o -q "$w" 'WEB-INF/web.xml' 'WEB-INF/weblogic.xml' 'WEB-INF/*.xml' 'WEB-INF/classes/*.properties' 'WEB-INF/classes/*.xml' -d "$OUT/G_descriptors/$n/$(basename "$w" .war)" 2>/dev/null
    done
  elif [ -d "$p" ]; then
    find "$p" -type f | sort >> "$OUT/D-5_artifacts.txt"
    ls "$p/WEB-INF/lib" > "$OUT/H-5_webinf_lib_$n.txt" 2>/dev/null
    mkdir -p "$OUT/G_descriptors/$n/WEB-INF" "$OUT/G_descriptors/$n/META-INF"
    cp -p "$p"/WEB-INF/*.xml "$p"/WEB-INF/classes/*.properties "$p"/WEB-INF/classes/*.xml "$OUT/G_descriptors/$n/WEB-INF/" 2>/dev/null
    cp -p "$p"/META-INF/*.xml "$OUT/G_descriptors/$n/META-INF/" 2>/dev/null
  fi
done
echo "  -> D-5_artifacts.txt, D_artifacts/, G_descriptors/, H-5_webinf_lib_*.txt"

#--- E/F. JDBC・その他リソース ----------------------------------------------------
run E-1_jdbc.txt <<'EOS'
awk '/<jdbc-system-resource>/,/<\/jdbc-system-resource>/' "$DOMAIN_HOME/config/config.xml"; echo
ls -la "$DOMAIN_HOME/config/jdbc"
for f in "$DOMAIN_HOME"/config/jdbc/*-jdbc.xml; do echo "===== $f"; cat "$f"; echo; done
echo '--- app-scoped jdbc modules'; find "$DOMAIN_HOME"/servers/*/tmp/_WL_user -name '*-jdbc.xml' 2>/dev/null
EOS
run E-5_jdbc_driver.txt <<'EOS'
ls -la "$WL_HOME"/server/lib/ojdbc*.jar "$WL_HOME"/server/ext/jdbc/oracle/*/ojdbc*.jar "$DOMAIN_HOME"/lib/*.jar 2>/dev/null
echo '--- classpath entries'; [ -n "$PID" ] && tr '\0' '\n' < /proc/$PID/cmdline | tr ':' '\n' | grep -i -E 'ojdbc|oracle|jdbc'
echo '--- in WEB-INF/lib'; find "$DOMAIN_HOME"/servers/*/tmp/_WL_user -name 'ojdbc*.jar' 2>/dev/null
echo '--- loaded'; [ -n "$PID" ] && ls -l /proc/$PID/fd 2>/dev/null | grep -i ojdbc
for j in "$WL_HOME"/server/lib/ojdbc*.jar "$WL_HOME"/server/ext/jdbc/oracle/*/ojdbc*.jar "$DOMAIN_HOME"/lib/ojdbc*.jar; do [ -f "$j" ] && { echo "== $j"; unzip -p "$j" META-INF/MANIFEST.MF | egrep -i 'Implementation-Version|Specification-Version|Implementation-Title'; }; done
EOS
run F_resources.txt <<'EOS'
for t in jms-server jms-system-resource saf-agent messaging-bridge mail-session foreign-jndi-provider file-store jdbc-store startup-class shutdown-class wldf-system-resource snmp-agent virtual-host cluster machine self-tuning jta web-app-container; do
  echo "===== <$t>"; awk "/<$t>/,/<\/$t>/" "$DOMAIN_HOME/config/config.xml"
done
ls -la "$DOMAIN_HOME/config/jms" "$DOMAIN_HOME/config/diagnostics" "$DOMAIN_HOME"/servers/*/data/store/* 2>/dev/null
cat "$DOMAIN_HOME"/config/jms/*.xml 2>/dev/null
EOS

#--- K/L. ログ・実績 -------------------------------------------------------------
mkdir -p "$OUT/K_logs"
run K-1_log_listing.txt <<'EOS'
ls -la "$DOMAIN_HOME"/servers/*/logs/ "$DOMAIN_HOME"/*.log /var/log/httpd/ 2>/dev/null
[ -n "$PID" ] && ls -l /proc/$PID/fd 2>/dev/null | awk '{print $NF}' | grep -i -E '\.log|\.out|\.txt|\.csv' | sort -u
head -3 "$DOMAIN_HOME"/servers/*/logs/access.log 2>/dev/null
EOS
for s in "$DOMAIN_HOME"/servers/*; do
  sn=$(basename "$s"); export s sn
  [ -f "$s/logs/$sn.log" ] || continue
  run K_logs/${sn}_startup_and_stats.txt <<'EOS'
SL="$s/logs/$sn.log"
START=$(grep -n 'BEA-000377' "$SL" | tail -1 | cut -d: -f1); END=$(grep -n 'BEA-000365.*RUNNING' "$SL" | tail -1 | cut -d: -f1)
echo "--- last startup sequence (lines $START-$END)"; [ -n "$START" ] && [ -n "$END" ] && sed -n "${START},${END}p" "$SL"
echo "--- restart history (RUNNING)"; grep 'BEA-000365' "$SL" | grep RUNNING | grep -oE '^####<[^>]+>' | tail -20
echo "--- message id counts (all rotated logs)"; cat "$s"/logs/$sn.log* | grep -oE '<BEA-[0-9]+>' | sort | uniq -c | sort -rn | head -60
echo "--- errors"; cat "$s"/logs/$sn.log* | grep -E '<Error>|<Critical>|<Emergency>' | grep -oE '<BEA-[0-9]+>' | sort | uniq -c | sort -rn
echo "--- stuck threads / OOM"; cat "$s"/logs/$sn.log* | grep -c 'BEA-000337'; cat "$s"/logs/$sn.log* | grep -i -c 'OutOfMemoryError'
echo "--- jdbc/jndi messages"; cat "$s"/logs/$sn.log* | grep -i -E 'Connection Pool named|Data Source named|JNDI Name' | sort -u | head -50
EOS
  tail -n 50000 "$s/logs/$sn.log" > "$OUT/K_logs/${sn}.log.tail50000" 2>/dev/null
  [ -f "$s/logs/$sn.out" ] && tail -n 5000 "$s/logs/$sn.out" > "$OUT/K_logs/${sn}.out.tail5000"
  if ls "$s"/logs/access.log* > /dev/null 2>&1; then
    run K_logs/${sn}_access_stats.txt <<'EOS'
LOGS="$s/logs/access.log*"
echo "--- files"; ls -la $LOGS; echo "--- total lines"; cat $LOGS | wc -l
echo "--- daily"; cat $LOGS | awk '{print substr($4,2,11)}' | sort | uniq -c | sort -k2 | tail -90
echo "--- peak minutes"; cat $LOGS | awk '{print substr($4,2,17)}' | sort | uniq -c | sort -rn | head -20
echo "--- by hour"; cat $LOGS | awk '{print substr($4,14,2)}' | sort | uniq -c
echo "--- top urls"; cat $LOGS | awk '{print $7}' | sed 's/?.*//' | sort | uniq -c | sort -rn | head -50
echo "--- status"; cat $LOGS | awk '{print $9}' | sort | uniq -c | sort -rn
echo "--- methods"; cat $LOGS | awk '{print $6}' | tr -d '"' | sort | uniq -c
echo "--- 5xx urls"; cat $LOGS | awk '$9>=500 {print $7}' | sed 's/?.*//' | sort | uniq -c | sort -rn | head -20
echo "--- client ips"; cat $LOGS | awk '{print $1}' | sort | uniq -c | sort -rn | head -10
EOS
  fi
done
run L-5_os_stats.txt <<'EOS'
uptime; vmstat 5 3; ls /var/log/sa/ 2>/dev/null
for f in /var/log/sa/sa[0-9]*; do [ -f "$f" ] && { echo "== $f"; sar -u -f "$f" | tail -3; sar -r -f "$f" | tail -2; sar -q -f "$f" | tail -2; }; done 2>/dev/null
EOS

#--- I/J. 前段・外部連携 ---------------------------------------------------------
run I-2_httpd.txt <<'EOS'
rpm -q httpd mod_ssl; httpd -v 2>/dev/null; httpd -M 2>/dev/null; httpd -S 2>/dev/null
ps -ef | grep '[h]ttpd' | head -5; ls -laR /etc/httpd/ 2>/dev/null | head -100
find /etc/httpd /usr/lib64/httpd /usr/lib/httpd -name 'mod_wl*' 2>/dev/null
grep -rn -i -E 'WebLogicHost|WebLogicPort|WebLogicCluster|MatchExpression|WLProxySSL|WLIOTimeoutSecs|WLLogFile|WLCookieName|PathTrim|PathPrepend|ConnectTimeoutSecs|WLSocketTimeoutSecs|KeepAliveEnabled|WLExcludePathOrMimeType|ProxyPass|RewriteRule|Listen|ServerName|DocumentRoot|SSLCertificateFile' /etc/httpd/ 2>/dev/null
ls -la /var/log/httpd/ 2>/dev/null
EOS
[ -d /etc/httpd ] && { mkdir -p "$OUT/I_httpd"; cp -rp /etc/httpd/conf /etc/httpd/conf.d "$OUT/I_httpd/" 2>/dev/null; }
run J_external.txt <<'EOS'
netstat -anp 2>/dev/null | grep ESTABLISHED | awk '{print $5}' | sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn
mount | egrep -i 'cifs|nfs|smb'; rpm -qa | egrep -i 'samba|cifs|nfs-utils|ftp|lftp|sendmail|postfix'
ps -ef | grep -i '[a]steria'; find /opt /home /usr/local -maxdepth 3 -iname '*asteria*' 2>/dev/null
echo '--- scripts referencing weblogic/t3 (H-12)'
find /home /opt /usr/local /etc/cron.d /var/spool/cron -maxdepth 4 -type f -size -2M \( -name '*.sh' -o -name '*.properties' -o -name '*.xml' -o -name '*.conf' -o -name '*.cfg' -o -name '*.py' -o -path '*/cron*' \) 2>/dev/null \
  | grep -v -E "^$MW_HOME|/tmp/_WL_user" | xargs -r grep -l -E 't3://|weblogic\.jar|wlfullclient|wlclient|WLInitialContextFactory' 2>/dev/null
EOS

#--- 終了 ------------------------------------------------------------------------
echo "### wls_survey.sh end: $(date)"
tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" && echo "DONE: $OUT.tar.gz ($(du -sh "$OUT.tar.gz" | cut -f1))"
```

### 付録 B. WLST 実績値取得スクリプト（wls_runtime_dump.py）

管理サーバに接続し、ServerRuntime 配下の実績値（JVM、スレッドプール、JTA、JDBC、Web アプリ/サーブレット）を一括表示する。参照のみで設定変更は行わない。Monitor ロール以上のユーザーで実行できる。WLST 10.3.4 は Jython 2.2 のため、その文法で記述している。

- 実行: `$WL_HOME/common/bin/wlst.sh wls_runtime_dump.py t3://<host>:7001 <user> <password> > <証跡>`（パスワードを引数で渡すのを避ける場合は、`connect()` を対話式にする）
- honban では要承認（接続のみで負荷は軽微）

```python
# wls_runtime_dump.py  (WLST online / Jython 2.2)
import sys
from java.util import Date

url = sys.argv[1]; user = sys.argv[2]; pwd = sys.argv[3]

def g(o, attr):
    try:
        return getattr(o, 'get' + attr)()
    except:
        try:
            return getattr(o, 'is' + attr)()
        except:
            return 'n/a'

def p(label, v):
    print '  %-42s %s' % (label, v)

connect(user, pwd, url)
domainRuntime()
for sr in cmo.getServerRuntimes():
    print '=' * 78
    print 'ServerRuntime: ' + sr.getName() + '   (collected ' + str(Date()) + ')'
    for a in ['State', 'HealthState', 'WeblogicVersion', 'ListenAddress', 'ListenPort', 'SSLListenPort',
              'AdminServerListenPort', 'OpenSocketsCurrentCount', 'RestartsTotalCount', 'CurrentMachine']:
        p(a, g(sr, a))
    p('ActivationTime', Date(g(sr, 'ActivationTime')))
    print '--- JVMRuntime'
    jvm = sr.getJVMRuntime()
    for a in ['JavaVersion', 'JavaVendor', 'JavaVMVendor', 'OSName', 'OSVersion', 'Uptime',
              'HeapSizeCurrent', 'HeapFreeCurrent', 'HeapSizeMax', 'HeapFreePercent']:
        p(a, g(jvm, a))
    print '--- ThreadPoolRuntime'
    tp = sr.getThreadPoolRuntime()
    for a in ['ExecuteThreadTotalCount', 'ExecuteThreadIdleCount', 'HoggingThreadCount', 'StandbyThreadCount',
              'QueueLength', 'PendingUserRequestCount', 'CompletedRequestCount', 'Throughput',
              'MinThreadsConstraintsPending', 'MinThreadsConstraintsCompleted', 'SharedCapacityForWorkManagers']:
        p(a, g(tp, a))
    print '--- JTARuntime'
    jta = sr.getJTARuntime()
    for a in ['TransactionTotalCount', 'TransactionCommittedTotalCount', 'TransactionRolledBackTotalCount',
              'TransactionRolledBackTimeoutTotalCount', 'TransactionRolledBackResourceTotalCount',
              'TransactionRolledBackAppTotalCount', 'TransactionAbandonedTotalCount', 'ActiveTransactionsTotalCount']:
        p(a, g(jta, a))
    print '--- JDBCDataSourceRuntime'
    jdbc = sr.getJDBCServiceRuntime()
    for ds in jdbc.getJDBCDataSourceRuntimeMBeans():
        print '  [DataSource] ' + ds.getName()
        for a in ['State', 'VersionJDBCDriver', 'ActiveConnectionsCurrentCount', 'ActiveConnectionsHighCount',
                  'ActiveConnectionsAverageCount', 'CurrCapacity', 'CurrCapacityHighCount', 'NumAvailable',
                  'NumUnavailable', 'HighestNumAvailable', 'HighestNumUnavailable', 'ConnectionsTotalCount',
                  'ReserveRequestCount', 'FailedReserveRequestCount', 'WaitingForConnectionCurrentCount',
                  'WaitingForConnectionHighCount', 'WaitingForConnectionTotal', 'WaitSecondsHighCount',
                  'LeakedConnectionCount', 'FailuresToReconnectCount', 'ConnectionDelayTime',
                  'PrepStmtCacheAccessCount', 'PrepStmtCacheHitCount', 'PrepStmtCacheMissCount', 'PrepStmtCacheCurrentSize']:
            p(a, g(ds, a))
    try:
        for mds in jdbc.getJDBCMultiDataSourceRuntimeMBeans():
            print '  [MultiDataSource] ' + mds.getName() + ' state=' + str(g(mds, 'State'))
    except:
        pass
    print '--- ApplicationRuntimes (WebApp / Servlet)'
    for app in sr.getApplicationRuntimes():
        for comp in app.getComponentRuntimes():
            if comp.getType() == 'WebAppComponentRuntime':
                print '  [WebApp] app=%s module=%s contextRoot=%s status=%s' % (app.getName(), comp.getName(), g(comp, 'ContextRoot'), g(comp, 'Status'))
                for a in ['OpenSessionsCurrentCount', 'OpenSessionsHighCount', 'SessionsOpenedTotalCount']:
                    p(a, g(comp, a))
                for sv in comp.getServlets():
                    if g(sv, 'InvocationTotalCount') > 0:
                        print '      servlet %-36s inv=%-8s avgMs=%-6s highMs=%-6s totalMs=%s' % (sv.getName(), g(sv, 'InvocationTotalCount'), g(sv, 'ExecutionTimeAverage'), g(sv, 'ExecutionTimeHigh'), g(sv, 'ExecutionTimeTotal'))
            elif comp.getType() in ['EJBComponentRuntime', 'JMSRuntime', 'ConnectorComponentRuntime']:
                print '  [%s] app=%s module=%s' % (comp.getType(), app.getName(), comp.getName())
disconnect()
exit()
```

参考: JNDI ツリーの一覧は管理コンソール（Servers > [server] > Configuration > General > View JNDI Tree）または診断イメージの `JNDI.txt` で取得する。WLST（Jython）から `weblogic.jndi.WLInitialContextFactory` で `InitialContext#listBindings` を再帰呼び出しして出力することもできる（`weblogic.jndi.internal.*` のサブコンテキストを再帰対象にする）。

### 付録 C. 管理コンソール画面一覧（確認パスと対応項目）

管理コンソール URL: `http://<host>:7001/console`（管理ポート有効時は `https://<host>:<admin port>/console`）。全て参照のみ。「Lock & Edit」は押さない。

| 画面パス（Domain Structure） | 確認内容 | 対応 No |
|---|---|---|
| [domain] > Configuration > General | ドメイン名、Production Mode、管理サーバ | C-1 |
| [domain] > Configuration > JTA / JPA / EJBs / Web Applications / Logging | JTA タイムアウト、ドメインレベル Web コンテナ設定、ドメインログ | C-10、C-6、C-7 |
| [domain] > Security > General / Embedded LDAP | セキュリティ設定、埋め込み LDAP | C-9 |
| [domain] > Monitoring > Health | 各サーバ・サブシステムのヘルス | L-6 |
| Environment > Servers | サーバ一覧（Name、Cluster、Machine、State、Health、Listen Port） | C-2 |
| Servers > [server] > Configuration > General | Listen Address/Port、SSL Listen Port、Machine、Cluster、**View JNDI Tree**、Advanced（WebLogic Plug-In Enabled、Client Cert Proxy 等） | C-2、C-6、E-6 |
| Servers > [server] > Configuration > Keystores / SSL | キーストア種別・パス、Identity/Trust、Hostname Verification、JSSE | C-8 |
| Servers > [server] > Configuration > Server Start | Node Manager 起動時の Java Home、Class Path、Arguments | B-4、C-4 |
| Servers > [server] > Configuration > Tuning / Overload / Health Monitoring | Accept Backlog、Stuck Thread Max Time、Native IO、過負荷保護 | C-5 |
| Servers > [server] > Configuration > Deployment | Staging Directory、Staging Mode、Upload Directory | D-1、D-2 |
| Servers > [server] > Protocols > General / HTTP / Channels | Complete Message Timeout、Max Message Size、Frontend Host/Port、Max Post Size、Post Timeout、Keep Alive、Send Server Header、ネットワークチャネル | C-2、C-6 |
| Servers > [server] > Logging > General / HTTP / Data Source | サーバログ・アクセスログ・JDBC ログの設定（ファイル名、ローテーション、重大度、形式） | C-7 |
| Servers > [server] > Monitoring > General / Health / Performance / Threads / Workload / JDBC / JTA | Activation Time、Java Version、Heap、Execute Thread 各カウント、Work Manager、DS 統計、JTA 統計 | L-2〜L-4、E-7 |
| Environment > Clusters / Machines / Virtual Hosts / Work Managers / Startup and Shutdown Classes | クラスタ、マシン、仮想ホスト、ワークマネージャ、起動クラス | C-3、C-5、C-12 |
| Deployments | アプリ一覧（Name、State、Health、Type、Targets、Deployment Order） | D-1 |
| Deployments > [app] > Overview / Deployment Plan / Configuration / Security / Targets / Control / Testing / Monitoring | Context Root、Path、Plan、Staging Mode、**プラン適用後の設定値**、Security Model、テスト URL、Web Applications/Servlets/Sessions 統計 | D-1、D-3、D-6、G-4、L-3 |
| Services > Data Sources > [DS] > Configuration（General / Connection Pool / Oracle / Transaction / Diagnostics）/ Targets / Monitoring / Security | JNDI 名、URL、ドライバ、プロパティ、プール設定、Init SQL、TX プロトコル、Multi DS/GridLink、統計 | E-1〜E-4、E-7 |
| Services > Messaging（JMS Servers / JMS Modules / Foreign Servers / Bridges / Store-and-Forward）| JMS 利用有無・内容 | F-1 |
| Services > Persistent Stores / Foreign JNDI Providers / Mail Sessions / XML Registries / Work Contexts / JTA | 永続ストア、外部 JNDI、メールセッション、JTA | F-2、F-3、F-6、C-10 |
| Security Realms > [realm] > Configuration / Users and Groups / Roles and Policies / Credential Mappings / Providers / Migration | レルム設定、ユーザー/グループ、ロール/ポリシー、プロバイダ種別、エクスポート | C-9 |
| Diagnostics > Log Files | 各ログの閲覧（ServerLog、DomainLog、HTTPAccessLog、DataSourceLog 等） | C-7、L-6 |
| Diagnostics > Diagnostic Modules / Diagnostic Images / Request Performance / Archives / SNMP | WLDF 設定、診断イメージの取得（要承認） | C-11、E-6 |

### 付録 D. 環境別 取得物チェックリスト

| 取得物 | 取得方法 | dev | qa | honban |
|---|---|---|---|---|
| 付録 A スクリプトの出力（tar.gz） | `wls_survey.sh` | ☐ | ☐ | ☐ |
| `config` ディレクトリ一式、`bin` ディレクトリ一式 | スクリプトに含む | ☐ | ☐ | ☐ |
| 稼働中成果物（EAR/WAR）と md5 | スクリプトに含む（共有ストレージへ格納） | ☐ | ☐ | ☐ |
| 記述子（web.xml、weblogic.xml、application.xml、weblogic-application.xml、plan.xml、Spring 設定） | スクリプトに含む | ☐ | ☐ | ☐ |
| 実プロセスの起動引数・環境変数 | スクリプトに含む | ☐ | ☐ | ☐ |
| 起動シーケンスログ、メッセージ ID 集計、アクセスログ集計 | スクリプトに含む | ☐ | ☐ | ☐ |
| BSU パッチ一覧、`java weblogic.version -verbose` | スクリプトに含む | ☐ | ☐ | ☐ |
| httpd 設定一式（同居時） | スクリプトに含む | ☐ | ☐ | ☐ |
| 管理コンソールのスクリーンショット（付録 C の各画面） | 手動 | ☐ | ☐ | ☐ |
| JNDI ツリー（View JNDI Tree） | 手動（スクリーンショット） | ☐ | ☐ | ☐ |
| WLST 実績値（付録 B） | 手動（要承認） | ☐ | ☐ | ☐ |
| スレッドダンプ（`jstack`/`jrcmd`） | 手動（要承認） | ☐ | ☐ | ☐ |
| GC ログ | 手動（存在する場合） | ☐ | ☐ | ☐ |
| キーストア内容（`keytool -list`） | 手動（パスフレーズ要） | ☐ | ☐ | ☐ |
| セキュリティレルムのユーザー/グループ一覧 | 手動（スクリーンショットまたはエクスポート） | ☐ | ☐ | ☐ |
| `jdeps` 結果（JDK 11 端末） | 手動 | ☐ | ☐ | ☐ |
| ソースの WebLogic 依存検索結果（H-1〜H-12） | 手動（リポジトリ） | ☐ | ☐ | ☐ |
| AWS 設定（ELB/SG/DNS/インスタンス/CloudWatch） | インフラ担当 | ☐ | ☐ | ☐ |
| DB 情報（版、キャラクタセット、ユーザー、セッション実績） | DBA | ☐ | ☐ | ☐ |
| ヒアリング記録（5.5） | 手動 | ☐ | ☐ | ☐ |
| 運用手順書・パラメータシート・リリース手順書のコピー | 運用担当 | ☐ | ☐ | ☐ |

### 付録 E. 用語・略語

| 用語 | 説明 |
|---|---|
| MW_HOME / WL_HOME / DOMAIN_HOME | 2.5 参照。WebLogic のインストール先とドメインディレクトリ |
| BSU（Smart Update） | WebLogic 10.3.x のパッチ適用ツール（`$MW_HOME/utils/bsu/bsu.sh`） |
| WLST | WebLogic Scripting Tool。Jython ベースの管理スクリプト環境（`$WL_HOME/common/bin/wlst.sh`） |
| WLDF | WebLogic Diagnostic Framework。診断モジュール・診断イメージ・ハーベスタ |
| Node Manager | WebLogic サーバプロセスの起動・停止・監視を行うデーモン（既定ポート 5556） |
| デプロイメントプラン（plan.xml） | 記述子の値を成果物を変更せずに上書きする XML |
| 共有ライブラリ（Shared Library） | 複数アプリで共有する WAR/JAR。`library-ref` で参照 |
| ステージングモード | stage（管理サーバから配布）/ nostage（配置先を直接参照）/ external_stage |
| T3 | WebLogic 独自の RMI プロトコル。`t3://host:port` |
| CommonJ | Work Manager / Timer Manager の API（`commonj.work`、`commonj.timers`） |
| Execute Thread / Hogging Thread / Stuck Thread | WebLogic の自己調整スレッドプールのスレッド、長時間占有スレッド、`stuck-thread-max-time` を超えたスレッド |
| Multi Data Source / GridLink Data Source | 複数 DS のフェイルオーバー/負荷分散、RAC 連携用 DS |
| JULI | Tomcat のロギング実装（`conf/logging.properties`） |
| Jasper / JspC | Tomcat の JSP エンジンと JSP プリコンパイラ |
| RemoteIpValve | Tomcat でプロキシ経由のクライアント IP・スキームを復元する Valve |

---

以上
