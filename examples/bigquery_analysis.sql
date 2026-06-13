-- =====================================================================
-- Amazon Connect 通話分析: BigQuery サンプル SQL
-- 前提: AWS 側で Contact Lens / Transcribe により文字起こし済みの
--       JSON/Parquet を BigQuery に取り込んだ状態。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. テーブル定義（1 通話 = 1 行、発話は配列で保持）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `myproject.connect.call_transcripts` (
  contact_id        STRING   NOT NULL,   -- Amazon Connect の ContactId
  instance_id       STRING,              -- Connect インスタンス
  queue_name        STRING,              -- キュー（診療科/業務）
  agent_id          STRING,              -- 担当オペレーター
  start_time        TIMESTAMP,
  duration_seconds  INT64,
  language_code     STRING,              -- ja-JP など
  overall_sentiment STRING,             -- POSITIVE / NEUTRAL / NEGATIVE
  categories        ARRAY<STRING>,       -- Contact Lens のカテゴリ
  transcript        STRING,              -- 全文（連結済み）
  utterances ARRAY<STRUCT<               -- 発話単位の明細
    participant STRING,                  -- CUSTOMER / AGENT
    begin_ms    INT64,
    end_ms      INT64,
    content     STRING,
    sentiment   STRING
  >>
)
PARTITION BY DATE(start_time)
CLUSTER BY queue_name, agent_id;

-- ---------------------------------------------------------------------
-- 2. 基本集計：キュー別・日別の件数と平均通話時間・ネガ率
-- ---------------------------------------------------------------------
SELECT
  DATE(start_time)                                   AS call_date,
  queue_name,
  COUNT(*)                                           AS call_count,
  ROUND(AVG(duration_seconds), 1)                    AS avg_duration_sec,
  ROUND(AVG(IF(overall_sentiment = 'NEGATIVE', 1, 0)) * 100, 1) AS negative_pct
FROM `myproject.connect.call_transcripts`
WHERE start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY call_date, queue_name
ORDER BY call_date DESC, call_count DESC;

-- ---------------------------------------------------------------------
-- 3. 顧客の発話だけを抽出（UNNEST で配列展開）
-- ---------------------------------------------------------------------
SELECT
  t.contact_id,
  u.begin_ms,
  u.content,
  u.sentiment
FROM `myproject.connect.call_transcripts` AS t,
     UNNEST(t.utterances) AS u
WHERE u.participant = 'CUSTOMER'
  AND u.sentiment = 'NEGATIVE'
ORDER BY t.contact_id, u.begin_ms;

-- ---------------------------------------------------------------------
-- 4. Gemini in BigQuery: トランスクリプトを要約 + 意図抽出
--    事前に CREATE MODEL でリモートモデル(Vertex AI Gemini)を作成しておく
-- ---------------------------------------------------------------------
-- CREATE OR REPLACE MODEL `myproject.connect.gemini`
--   REMOTE WITH CONNECTION `myproject.us.vertex_conn`
--   OPTIONS (endpoint = 'gemini-1.5-pro');

SELECT
  contact_id,
  ml_generate_text_result['candidates'][0]['content']['parts'][0]['text'] AS summary
FROM ML.GENERATE_TEXT(
  MODEL `myproject.connect.gemini`,
  (
    SELECT
      contact_id,
      CONCAT(
        'あなたはコールセンター品質管理者です。次の通話内容を3行で要約し、',
        '顧客の主な要望と未解決事項を箇条書きで示してください:\n\n',
        transcript
      ) AS prompt
    FROM `myproject.connect.call_transcripts`
    WHERE DATE(start_time) = CURRENT_DATE()
  ),
  STRUCT(0.2 AS temperature, 1024 AS max_output_tokens)
);

-- ---------------------------------------------------------------------
-- 5. BigQuery ML: 解約リスクの分類モデル（例: ロジスティック回帰）
-- ---------------------------------------------------------------------
-- CREATE OR REPLACE MODEL `myproject.connect.churn_model`
-- OPTIONS (model_type = 'LOGISTIC_REG', input_label_cols = ['churned']) AS
-- SELECT
--   duration_seconds,
--   (SELECT COUNTIF(sentiment = 'NEGATIVE') FROM UNNEST(utterances)) AS neg_utterances,
--   ARRAY_LENGTH(categories) AS category_count,
--   churned
-- FROM `myproject.connect.call_labeled`;
