--- description: Get RUM data by checkpoint to see which checkpoint causes the greatest dropoff in traffic
--- Authorization: none
--- interval: 30
--- offset: 0
--- startdate: 2022-02-01
--- enddate: 2022-05-28
--- timezone: UTC
--- url: -
--- device: all
--- domainkey: secret

WITH
weightdata AS (
  SELECT
    checkpoint,
    id,
    MAX(pageviews) AS weight,
    ANY_VALUE(url) AS url,
  FROM
    helix_rum.CHECKPOINTS_V3(
      @url,
      CAST(@offset AS INT64), # offset in days
      CAST(@interval AS INT64), # interval in days to consider
      @startdate, # start date
      @enddate, # end date
      @timezone, # timezone
      'all', # device class
      @domainkey # domain key
    )
  GROUP BY id, checkpoint
),

data AS (
  SELECT
    checkpoint,
    COUNT(DISTINCT id) AS ids,
    SUM(weight) AS views
  # url
  FROM weightdata
  WHERE
    checkpoint IS NOT NULL
  GROUP BY
    checkpoint
  #, url
  ORDER BY ids DESC
),

anydatabyid AS (
  SELECT
    'any' AS checkpoint,
    COUNT(DISTINCT id) AS ids,
    MAX(weight) AS views
  # url
  FROM weightdata
  WHERE
    checkpoint IS NOT NULL #IN ("top", "unsupported", "noscript")
  GROUP BY
    id
  ORDER BY ids DESC
),

anydata AS (
  SELECT
    MIN(checkpoint) AS checkpoint,
    COUNT(DISTINCT ids) AS ids,
    SUM(views) AS views
  #, url
  FROM anydatabyid
),

alldata AS (
  SELECT * FROM (
    SELECT * FROM anydata
    UNION ALL
    (SELECT * FROM data)
  )
)

-- SELECT * FROM anydatabyid LIMIT 10

SELECT
  checkpoint,
  ids AS events,
  views,
  IF(MAX(views) OVER (
    ORDER BY views DESC
    ROWS BETWEEN 1 PRECEDING AND 0 FOLLOWING
  ) != 0, ROUND(100 - (100 * views / MAX(views) OVER (
    ORDER BY views DESC
    ROWS BETWEEN 1 PRECEDING AND 0 FOLLOWING
  )), 1), 0) AS percent_dropoff,
  IF(MAX(views) OVER (
    ORDER BY views DESC) != 0, ROUND(100 * views / MAX(views) OVER (
    ORDER BY views DESC
  ), 1), 0) AS percent_total

FROM alldata
