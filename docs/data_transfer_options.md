# S3 → GCP データ転送方式の選び方

> WAV を直接ロード/クエリできる方式は**ない**（いずれもテキスト/構造化データ化が前提）。
> 文字起こし済みの JSON/Parquet を前提に、3 方式を比較する。

| 方式 | 何ができる | 向くケース | 備考 |
|------|-----------|-----------|------|
| **BigQuery Data Transfer Service（Amazon S3 コネクタ）** | S3 の CSV/JSON/Parquet 等を**直接 BigQuery へ定期ロード**（GCS 不要） | 文字起こし済み JSON/Parquet を**定期バッチ**で BQ に取り込む（案 A の本命） | スケジュール実行。差分取り込み可 |
| **Storage Transfer Service** | S3 → **GCS** へファイル同期（WAV 含む任意ファイル） | 案 B で音声を移す／GCS にデータレイク化したい | 大容量・定期同期に強い |
| **BigQuery Omni（BigLake / AWS 接続）** | **S3 上のデータを移動せず BigQuery からクエリ**（in-place） | データを GCP に移したくない／ガバナンス上 S3 に留置きたい | 対応リージョン制約あり。構造化データのみ |

## 選択フロー

```
文字起こし済みデータを BQ で分析したい
        │
        ├─ データを GCP に移したくない（S3 留置） ─────▶ BigQuery Omni（in-place クエリ）
        │
        ├─ S3 の JSON/Parquet を定期で BQ に入れたい ──▶ BigQuery Data Transfer Service（S3 コネクタ）
        │
        └─ 音声/任意ファイルを GCS に集約したい ───────▶ Storage Transfer Service → GCS → BQ ロード
```

## 認証の要点

- **Data Transfer / Storage Transfer**: AWS 側に**読み取り専用ロール/キー**。可能なら **Workload Identity 連携(OIDC)**。
- **BigQuery Omni**: GCP に **AWS connection** を作成し AWS IAM ロールを信頼。
- 転送は TLS、保存は KMS/CMEK で暗号化。
