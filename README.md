# Amazon Connect (S3 WAV) → GCP BigQuery 分析アーキテクチャ

> Amazon Connect の通話録音（S3 に保存された WAV ファイル）を GCP BigQuery へ渡して分析するための
> クロスクラウド・アーキテクチャ設計ノート。

## 前提：音声は「文字起こし」を経て分析（BigQuery 内でも可能）

音声(WAV)を「通常のテーブル列」として直接分析することはできませんが、**BigQuery は
オブジェクトテーブル + `ML.TRANSCRIBE` / `AI.GENERATE` 等の AI 関数で、SQL から音声を
文字起こし・分析できます**（非構造化データ対応）。

```
音声(WAV) → 文字起こし(テキスト) → 分析
            ↑ このステップを AWS / GCP自前 / BigQueryネイティブ のどれで行うかが分岐点
```

設計の分岐点は「**文字起こしを AWS 側(案A)・GCP 自前(案B)・BigQuery ネイティブ(案C)のどれで行うか**」です。

## 推奨構成（案A：AWS 側で文字起こし）

```
Amazon Connect ─(録音)→ S3(WAV)
     │ Contact Lens / Amazon Transcribe（+ PII編集）
     ▼
S3(分析用 JSON/Parquet)
     │ BigQuery Data Transfer Service(S3コネクタ) / Storage Transfer / BigQuery Omni
     ▼
BigQuery テーブル → SQL / BigQuery ML / Gemini in BigQuery → Looker Studio
```

コンタクトセンター分析では、**AWS 側で文字起こし＋感情分析まで済ませ、軽量なテキスト/JSON だけを GCP に渡す**のが
コスト・PII リスク・実装容易性のバランスで最良。

## ドキュメント

- [アーキテクチャ詳細（案A/案B/案C・転送方式比較・認証・分析）](./docs/architecture.md)
- [BigQuery 分析サンプル SQL（テーブル定義・集計・Gemini）](./examples/bigquery_analysis.sql)
- [BigQuery ネイティブ 非構造化音声分析 SQL（オブジェクトテーブル + ML.TRANSCRIBE）](./examples/bigquery_unstructured.sql)
- [データ転送方式の選び方](./docs/data_transfer_options.md)

## 関連
- AWS 学習ノート: [aws-aip-c01-study](https://github.com/TetsuSuzu/aws-aip-c01-study)
