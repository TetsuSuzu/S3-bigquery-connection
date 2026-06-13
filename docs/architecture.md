# アーキテクチャ詳細

## ⚠️ 最重要の前提：WAV は直接 BigQuery に入らない

BigQuery は**構造化データ/テキストを分析する**サービスで、**生の音声(WAV)は分析できない**。
したがってどの構成でも必ず

> 音声(WAV) → 文字起こし(テキスト/JSON) → BigQuery

という**文字起こし(transcription)ステップ**が入る。設計の分岐点は「**文字起こしを AWS 側でやるか GCP 側でやるか**」。

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

## まとめ：おすすめは案A

| 観点 | 案A（AWS 文字起こし） | 案B（GCP 文字起こし） |
|------|-----------------|-----------------|
| 越境データ | **テキスト/JSON（軽い）** | 音声 WAV（重い） |
| コスト | 低い | 高い（転送・保管） |
| PII リスク | 低い（事前 redaction 可） | 高い |
| Connect 親和性 | **高い（Contact Lens 統合）** | 低い |

**結論**: Amazon Connect → S3(WAV) → **Contact Lens/Transcribe でテキスト化＋PII 編集** →
**BigQuery Data Transfer Service（または BigQuery Omni で in-place クエリ）** → BigQuery で分析、が
コスト効率・セキュリティ・実装容易性のバランスで最良。
