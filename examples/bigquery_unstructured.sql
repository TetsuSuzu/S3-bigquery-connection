-- =====================================================================
-- 案C: BigQuery ネイティブで非構造化音声(WAV)を分析する
--   オブジェクトテーブル + ML.TRANSCRIBE + ML.GENERATE_TEXT
-- 前提:
--   - S3 の WAV を Storage Transfer Service で GCS (gs://connect-recordings/) に転送済み
--   - BigLake 用の Cloud Resource 接続と、Speech-to-Text / Vertex AI への
--     リモートモデルを作成済み
-- ※関数名・構文はリージョン/エディションにより差異あり。公式ドキュメントで最新を確認すること。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 接続(BigLake)。GCS 上の非構造化データを参照するための Cloud Resource 接続
--    (bq mk --connection などで作成済みのものを利用)
-- ---------------------------------------------------------------------
-- 例: `myproject.us.biglake_conn`

-- ---------------------------------------------------------------------
-- 1. オブジェクトテーブル: GCS の WAV をテーブルとして参照(読み取り専用)
-- ---------------------------------------------------------------------
CREATE OR REPLACE EXTERNAL TABLE `myproject.connect.recordings_obj`
WITH CONNECTION `myproject.us.biglake_conn`
OPTIONS (
  object_metadata = 'SIMPLE',
  uris = ['gs://connect-recordings/CallRecordings/*.wav'],
  metadata_cache_mode = 'AUTOMATIC',
  max_staleness = INTERVAL 1 HOUR
);

-- ---------------------------------------------------------------------
-- 2. 音声認識用リモートモデル(Cloud Speech-to-Text の recognizer に接続)
-- ---------------------------------------------------------------------
CREATE OR REPLACE MODEL `myproject.connect.transcriber`
REMOTE WITH CONNECTION `myproject.us.biglake_conn`
OPTIONS (
  remote_service_type = 'CLOUD_AI_SPEECH_TO_TEXT_V2',
  speech_recognizer = 'projects/myproject/locations/us/recognizers/connect-ja'
);

-- ---------------------------------------------------------------------
-- 3. ML.TRANSCRIBE: オブジェクトテーブルの音声を SQL で文字起こし
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `myproject.connect.transcripts` AS
SELECT
  uri,                                   -- 元 WAV の GCS パス
  REGEXP_EXTRACT(uri, r'/([^/]+)\.wav$') AS contact_id,
  transcripts,                           -- 文字起こし結果(全文/セグメント)
  ml_transcribe_status                   -- エラー情報
FROM ML.TRANSCRIBE(
  MODEL `myproject.connect.transcriber`,
  TABLE `myproject.connect.recordings_obj`,
  RECOGNITION_CONFIG => (
    JSON '{"features": {"enableAutomaticPunctuation": true}}'
  )
);

-- ---------------------------------------------------------------------
-- 4. Gemini で要約・感情・意図抽出(マルチモーダル/テキスト)
--    事前に Vertex AI への REMOTE MODEL (gemini) を作成しておく
-- ---------------------------------------------------------------------
-- CREATE OR REPLACE MODEL `myproject.connect.gemini`
--   REMOTE WITH CONNECTION `myproject.us.vertex_conn`
--   OPTIONS (endpoint = 'gemini-1.5-pro');

SELECT
  contact_id,
  AI.GENERATE(
    CONCAT(
      'この通話を3行で要約し、顧客の感情(POSITIVE/NEUTRAL/NEGATIVE)と',
      '主な要望、未解決事項をJSONで返してください:\n\n',
      transcripts
    ),
    connection_id => 'myproject.us.vertex_conn',
    endpoint => 'gemini-1.5-pro'
  ).result AS analysis
FROM `myproject.connect.transcripts`
WHERE ml_transcribe_status = '';

-- ---------------------------------------------------------------------
-- 参考: 画像/PDF も同様にオブジェクトテーブル + 以下の関数で分析可能
--   ML.ANNOTATE_IMAGE  … 画像認識(Vision)
--   ML.PROCESS_DOCUMENT… 文書処理(Document AI)
--   ML.UNDERSTAND_TEXT … NLP / ML.TRANSLATE … 翻訳
-- ---------------------------------------------------------------------
