--- description: Get popularity data for RUM target attribute values, filtered by checkpoint
--- Authorization: none
--- Access-Control-Allow-Origin: *
--- limit: 30
--- interval: 30
--- offset: 0
--- startdate: 2022-01-01
--- enddate: 2022-01-31
--- timezone: UTC
--- url: -
--- checkpoint: -
--- source: -
--- separator: ;
--- extract: -
--- domainkey: secret

WITH
current_data AS (
  SELECT
    *,
    TIMESTAMP_TRUNC(time, DAY) AS date
  FROM
    helix_rum.CHECKPOINTS_V3(
      @url,
      CAST(@offset AS INT64),
      CAST(@interval AS INT64),
      @startdate,
      @enddate,
      @timezone,
      'all',
      @domainkey
    )
),

targets AS (
  SELECT
    id,
    target,
    checkpoint,
    REGEXP_REPLACE(MAX(url), r'\?.*$', '') AS url,
    MAX(pageviews) AS views
  FROM current_data
  WHERE
    target IS NOT NULL
    AND (
      CAST(
        @checkpoint AS STRING
      ) = '-' OR CAST(@checkpoint AS STRING) = checkpoint
    )
    AND (@source = '-' OR @source = source)
  GROUP BY target, id, checkpoint
)

SELECT
  checkpoint,
  target,
  COUNT(id) AS ids,
  COUNT(DISTINCT url) AS pages,
  APPROX_TOP_COUNT(url, 1)[OFFSET(0)].value AS topurl,
  SUM(views) AS views
FROM
  targets,
  UNNEST(
    IF(
      @extract = '-',
      SPLIT(target, CONCAT(@separator, ' ')),
      REGEXP_EXTRACT_ALL(target, @extract)
    )
  ) AS target
GROUP BY target, checkpoint
ORDER BY views DESC
LIMIT @limit
