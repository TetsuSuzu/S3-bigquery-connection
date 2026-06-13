# アーキテクチャ詳細

## 前提：音声は「文字起こし」を経て分析する（ただし BigQuery 内でも可能）

**訂正（重要）**: 当初「WAV は BigQuery で分析できない」と記したが、これは不正確。
BigQuery は **オブジェクトテーブル(Object tables / BigLake)** で GCS 上の非構造化ファイル（音声・画像・PDF）を
参照でき、**`ML.TRANSCRIBE`**（裏で Cloud Speech-to-Text）や **`ML.GENERATE_TEXT` / `AI.GENERATE`（マルチモーダル）**
などの AI 関数で、**SQL から音声を文字起こし・分析できる**。

正確には次のとおり:

- ❌ raw WAV を「通常のテーブル列」としてそのまま分析することはできない
- ✅ **オブジェクトテーブル + `ML.TRANSCRIBE` 等の AI 関数**で、BigQuery 内から音声を文字起こし・分析できる

つまりどの構成でも「音声 → テキスト化」は必須だが、**そのステップを外部パイプラインで行うか(案A/B)、
BigQuery 自身が SQL で行うか(案C)** が設計の分岐点。

> S3 との関係: オブジェクトテーブルは **GCS 上のファイルが対象**。S3 の WAV を直接は参照できないため、
> 案C でも **S3 → GCS への転送(Storage Transfer Service)は必要**。BigQuery Omni(AWS/S3 の in-place クエリ)は
> 構造化データ向けで、object table + `ML.TRANSCRIBE` のフル機能は GCS 前提と考えるのが安全。

BigQuery が提供する主な非構造化/AI 関数:

| 仕組み | 用途 |
|--------|------|
| オブジェクトテーブル(Object tables/BigLake) | GCS の非構造化ファイル(音声/画像/PDF)をテーブル参照 |
| `ML.TRANSCRIBE` | 音声を SQL から文字起こし(Cloud Speech-to-Text) |
| `ML.GENERATE_TEXT` / `AI.GENERATE` | 音声/画像/文書を Gemini で要約・分類・抽出(マルチモーダル) |
| `ML.PROCESS_DOCUMENT` / `ML.ANNOTATE_IMAGE` / `ML.UNDERSTAND_TEXT` / `ML.TRANSLATE` | 文書処理 / 画像認識 / NLP / 翻訳 |

---

## 案A（推奨）：AWS 側で文字起こし

AWS 側で Transcribe / Contact Lens を使って文字起こし＋感情分析まで済ませ、その「テキスト/JSON」だけを GCP へ渡す。
音声より軽く、転送コスト・PII リスクも減る。

```
┌──────────────────────── AWS ────────────────────────┐
│                                                       │
│  Amazon Connect ──(通話録音)──▶ S3 (WAV)              │
│        │                          │                   │
│        │ Contact Lens             │ S3イベント通知     │
│        ▼ (リアルタイム/事後)        ▼ (EventBridge)     │
│  ┌──────────────────┐      ┌──────────────┐          │
│  │ 文字起こし+感情    │      │ Lambda        │          │
│  │ ・Contact Lens     │      │ (整形/正規化) │          │
│  │ ・Amazon Transcribe│─────▶│ JSON/Parquet  │          │
│  └──────────────────┘      └──────┬───────┘          │
│                                    ▼                   │
│                            S3 (分析用 JSON/Parquet)    │
└────────────────────────────────────┬──────────────────┘
                                      │ クロスクラウド転送
                                      ▼
┌──────────────────────── GCP ────────────────────────┐
│   Storage Transfer Service / BigQuery Data Transfer   │
│   Service / BigQuery Omni                             │
│                  │                                     │
│                  ▼                                     │
│   GCS ──(ロード)──▶ BigQuery テーブル                  │
│                          │                             │
│                          ▼ 分析                        │
│   ・SQL集計  ・BigQuery ML  ・Gemini in BigQuery       │
│   ・Looker / Looker Studio で可視化                    │
└───────────────────────────────────────────────────────┘
```

**フロー**
1. Amazon Connect の通話録音が **S3 に WAV** で保存される。
2. **Contact Lens**（リアルタイム/通話後分析）または **Amazon Transcribe**（バッチ文字起こしジョブ）で
   **トランスクリプト＋感情・カテゴリ**を JSON 生成。
3. Lambda で BigQuery が扱いやすい形（**改行区切り JSON または Parquet**、1 通話=1 行＋発話配列など）に整形。
4. **S3 → GCP** へ転送。
5. BigQuery にロードし、SQL / BigQuery ML / Gemini で分析、Looker Studio で可視化。

---

## 案B：GCP 側で文字起こし

GCP の音声認識（Speech-to-Text / Chirp）を使う場合。

```
S3 (WAV) ──Storage Transfer Service──▶ GCS (WAV)
                                          │ オブジェクト作成トリガー
                                          ▼
                                  Cloud Run / Functions
                                          │ 呼び出し
                                          ▼
                            Google Speech-to-Text (Chirp)
                                          │ トランスクリプト
                                          ▼
                                   BigQuery テーブル ──▶ 分析
```

- **メリット**: GCP のマルチリンガル音声モデルを使える／パイプラインを GCP に寄せられる。
- **デメリット**: **音声ファイルそのものを越境転送**するため**転送量・コスト・PII 露出が大きい**。
  コンタクトセンター用途では案 A が有利なことが多い。

---

## 案C（BigQuery ネイティブ）：オブジェクトテーブル + `ML.TRANSCRIBE`

外部の Cloud Functions 等を使わず、**BigQuery の SQL だけで「音声 → 文字起こし → 分析」を完結**させる。
最も "BigQuery らしい" 構成。

```
S3 (WAV) ──Storage Transfer Service──▶ GCS (WAV)
                                          │
                                          ▼
                              BigQuery オブジェクトテーブル (音声参照)
                                          │ ML.TRANSCRIBE (SQL)
                                          ▼
                              トランスクリプト列を持つテーブル
                                          │ ML.GENERATE_TEXT / AI.GENERATE
                                          ▼
                              要約・感情・意図抽出 → 分析・可視化
```

- **メリット**: パイプラインが SQL に集約され運用がシンプル。Gemini でそのまま深い分析へ。
- **デメリット**: 音声を GCS へ移す必要（越境コスト/PII は案 A より大）。対応リージョン・エディションの制約に注意。
- 実装例: [examples/bigquery_unstructured.sql](../examples/bigquery_unstructured.sql)

---

## クロスクラウドの認証・セキュリティ

- **Storage Transfer Service / BigQuery Data Transfer**: AWS 側に**読み取り専用 IAM ロール/アクセスキー**。
  可能なら **Workload Identity 連携(OIDC)** で長期アクセスキーの保管を避ける。
- **BigQuery Omni**: GCP 側に **AWS 接続(connection)** を作り AWS IAM ロールを信頼させる。
- **PII 対策**: 医療・保険系なら AWS 側で **Comprehend / Transcribe の PII 編集(redaction)** を通してから越境。
  S3・GCS・BQ すべてで**保存時暗号化(KMS/CMEK)**、転送は TLS。
- **データレジデンシー**: 音声＝個人情報。どのリージョン/国に置くか事前確認。可能なら**音声は越境させずテキストのみ**（案A）。

---

## 分析イメージ（BigQuery 側）

- **SQL 集計**: 通話数、平均通話時間、感情スコア推移、カテゴリ別件数。
- **BigQuery ML**: 解約予測、トピッククラスタリング、感情分類。
- **Gemini in BigQuery (`ML.GENERATE_TEXT`)**: トランスクリプトの**要約・意図抽出・コンプラ違反検知**を SQL から直接実行。
- **可視化**: Looker / Looker Studio。

---

## まとめ：3 案の比較

| 観点 | 案A（AWS 文字起こし） | 案B（GCP 自前文字起こし） | 案C（BigQuery ネイティブ） |
|------|-----------------|-----------------|------------------|
| 文字起こし場所 | AWS (Transcribe/Contact Lens) | GCP (Cloud Functions + Speech-to-Text) | **BigQuery SQL (`ML.TRANSCRIBE`)** |
| 越境データ | **テキスト/JSON（軽い）** | 音声 WAV（重い） | 音声 WAV（重い） |
| コスト | 低い | 高い | 中（転送あり/運用は軽い） |
| PII リスク | **低い（事前 redaction 可）** | 高い | 高い |
| Connect 親和性 | **高い（Contact Lens 統合）** | 低い | 低い |
| 運用のシンプルさ | 中 | 低い | **高い（SQL に集約）** |

**使い分け**
- **越境コスト・PII を最小化したい / Contact Lens を活かす** → **案A**（AWS でテキスト化し軽量データのみ転送）。
- **GCP に寄せて SQL だけで完結させたい / Gemini で深く分析したい** → **案C**（GCS に音声を集約し BigQuery ネイティブ）。
- 案B は案C で代替できることが多く、Cloud Functions の作り込みが要る分だけ不利。

コンタクトセンター用途で迷ったら、まず **案A**（コスト/PII 最小）、GCP 主導で分析を深めたいなら **案C** を推奨。
