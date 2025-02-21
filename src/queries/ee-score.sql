--- description: Show content reach and persistence over time
--- Authorization: none
--- Access-Control-Allow-Origin: *
--- limit: 30
--- interval: 60
--- startdate: 01-01-2020
--- enddate: 01-01-2021
--- timezone: UTC
--- offset: 0
--- url: -
--- domainkey: secret
DECLARE upperdate STRING DEFAULT CONCAT(
  CAST(
    EXTRACT(
      YEAR FROM TIMESTAMP_SUB(
        CURRENT_TIMESTAMP(), INTERVAL CAST(@offset AS INT64) DAY
      )
    ) AS String
  ),
  LPAD(CAST(EXTRACT(MONTH FROM TIMESTAMP_SUB(
    CURRENT_TIMESTAMP(),
    INTERVAL CAST(@offset AS INT64) DAY
  )) AS String), 2, "0")
);

DECLARE lowerdate STRING DEFAULT CONCAT(
  CAST(
    EXTRACT(
      YEAR FROM TIMESTAMP_SUB(
        CURRENT_TIMESTAMP(),
        INTERVAL SAFE_ADD(CAST(@interval AS INT64), CAST(@offset AS INT64)) DAY
      )
    ) AS String
  ),
  LPAD(CAST(EXTRACT(MONTH FROM TIMESTAMP_SUB(
    CURRENT_TIMESTAMP(),
    INTERVAL SAFE_ADD(CAST(@interval AS INT64), CAST(@offset AS INT64)) DAY
  )) AS String), 2, "0")
);

DECLARE uppertimestamp STRING DEFAULT CAST(
  UNIX_MICROS(
    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL CAST(@offset AS INT64) DAY)
  ) AS STRING
);

DECLARE lowertimestamp STRING DEFAULT CAST(
  UNIX_MICROS(
    TIMESTAMP_SUB(
      CURRENT_TIMESTAMP(),
      INTERVAL SAFE_ADD(CAST(@interval AS INT64), CAST(@offset AS INT64)) DAY
    )
  ) AS STRING
);

CREATE TEMP FUNCTION LABELSCORE(score FLOAT64)
RETURNS STRING
AS (
  IF(
    score <= 1,
    "A",
    IF(score <= 2, "B", IF(score <= 3, "C", IF(score <= 4, "D", "F")))
  )
);

WITH visits AS (
  SELECT
    id,
    REGEXP_REPLACE(ANY_VALUE(url), "\\?.*$", "") AS url,
    ANY_VALUE(hostname) AS host,
    TIMESTAMP_TRUNC(MAX(time), DAY) AS visittime,
    MAX(weight) AS weight,
    MAX(lcp) AS lcp,
    MAX(cls) AS cls,
    MAX(fid) AS fid,
    MAX(inp) AS inp,
    MAX(IF(checkpoint = "top", 1, 0)) AS top,
    MAX(IF(checkpoint = "load", 1, 0)) AS load,
    MAX(IF(checkpoint = "click", 1, 0)) AS click
  FROM
    helix_rum.EVENTS_V3(
      @url,
      CAST(@offset AS INT64),
      CAST(@interval AS INT64),
      @startdate,
      @enddate,
      @timezone,
      "all",
      @domainkey
    )
  GROUP BY id
),

urldays AS (
  SELECT
    visittime,
    url,
    MAX(host) AS host,
    COUNT(id) AS events,
    SUM(weight) AS visits,
    AVG(lcp) AS lcp,
    AVG(cls) AS cls,
    AVG(fid) AS fid,
    AVG(inp) AS inp,
    LEAST(IF(SUM(top) > 0, SUM(load) / SUM(top), 0), 1) AS load,
    LEAST(IF(SUM(top) > 0, SUM(click) / SUM(top), 0), 1) AS click
  FROM visits # FULL JOIN days ON (days.visittime = visits.visittime)
  GROUP BY visittime, url
),

steps AS (
  SELECT
    visittime,
    url,
    host,
    events,
    visits,
    lcp,
    cls,
    fid,
    inp,
    load,
    click,
    TIMESTAMP_DIFF(
      visittime, LAG(visittime) OVER (PARTITION BY url ORDER BY visittime), DAY
    ) AS step
  FROM urldays
),

chains AS (
  SELECT
    visittime,
    url,
    host,
    events,
    visits,
    lcp,
    cls,
    fid,
    inp,
    load,
    click,
    step,
    COUNTIF(step = 1) OVER (PARTITION BY url ORDER BY visittime) AS chainlength
  FROM steps
),

# urlchains AS (
#  SELECT
#    url,
#    time,
#    chain,
#    events,
#    visits
#  FROM chains
#  ORDER BY chain DESC
# ),
#
# powercurve AS (
#  SELECT
#    MAX(chain) AS persistence,
#    COUNT(url) AS reach
#  FROM urlchains
#  GROUP BY chain
#  ORDER BY MAX(chain) ASC
#  LIMIT 31 OFFSET 1
# ),

powercurvequintiles AS (
  SELECT
    APPROX_QUANTILES(DISTINCT reach, 3) AS reach,
    APPROX_QUANTILES(DISTINCT persistence, 3) AS persistence
  FROM (
    SELECT * FROM (
      SELECT
        host,
        COUNTIF(chainlength = 1) AS reach,
        COUNTIF(chainlength = 7) AS persistence
      FROM chains
      GROUP BY host
    )
    WHERE reach > 0 AND persistence > 0 AND host IS NOT NULL
  )
),

cwvquintiles AS (
  SELECT
    APPROX_QUANTILES(DISTINCT lcp, 3) AS lcp,
    APPROX_QUANTILES(DISTINCT cls, 3) AS cls,
    APPROX_QUANTILES(DISTINCT fid, 3) AS fid,
    APPROX_QUANTILES(DISTINCT inp, 3) AS inp,
    APPROX_QUANTILES(DISTINCT load, 3) AS load,
    APPROX_QUANTILES(DISTINCT click, 3) AS click
  FROM chains
),

cwvquintiletable AS (
  SELECT
    num,
    lcp[OFFSET(num)] AS lcp,
    cls[OFFSET(num)] AS cls,
    fid[OFFSET(num)] AS fid,
    inp[OFFSET(num)] AS inp,
    load[OFFSET(3 - num)] AS load,
    click[OFFSET(3 - num)] AS click
  FROM cwvquintiles INNER JOIN UNNEST(GENERATE_ARRAY(0, 3)) AS num
),

powercurvequintiletable AS (
  SELECT
    num,
    reach[OFFSET(3 - num)] AS reach,
    persistence[OFFSET(3 - num)] AS persistence
  FROM powercurvequintiles INNER JOIN UNNEST(GENERATE_ARRAY(0, 3)) AS num
),

quintiletable AS (
  # SELECT * FROM powercurve
  SELECT
    cwvquintiletable.cls AS cls,
    cwvquintiletable.lcp AS lcp,
    cwvquintiletable.fid AS fid,
    cwvquintiletable.inp AS inp,
    cwvquintiletable.load AS load,
    cwvquintiletable.click AS click,
    powercurvequintiletable.reach AS reach,
    powercurvequintiletable.persistence AS persistence,
    cwvquintiletable.num AS num
  FROM
    powercurvequintiletable
  INNER JOIN
    cwvquintiletable ON powercurvequintiletable.num = cwvquintiletable.num
),

lookmeup AS (
  SELECT
    host,
    LABELSCORE(
      (
        (
          # todo: replace FID with INP in April 2024
          (clsscore + lcpscore + fidscore) / 3
        ) + ((reachscore + persistencescore + loadscore) / 3) + (clickscore)
      ) / 3
    ) AS experiencescore,
    # todo: replace FID with INP in April 2024
    LABELSCORE((clsscore + lcpscore + fidscore) / 3) AS perfscore,
    LABELSCORE(
      (reachscore + persistencescore + loadscore) / 3
    ) AS audiencescore,
    LABELSCORE(clickscore) AS engagementscore
  FROM (
    SELECT
      host,
      chained.cls AS cls,
      # (SELECT num FROM quintiletable WHERE quintiletable.CLS <= chained.CLS) AS clsscore,
      chained.lcp AS lcp,
      chained.fid AS fid,
      chained.inp AS inp,
      chained.load AS load,
      chained.click AS click,
      chained.reach AS reach,
      chained.persistence AS persistence,
      (
        SELECT MAX(num)
        FROM
          (SELECT num FROM quintiletable WHERE quintiletable.cls <= chained.cls)
      ) AS clsscore,
      (
        SELECT MAX(num)
        FROM
          (SELECT num FROM quintiletable WHERE quintiletable.lcp <= chained.lcp)
      ) AS lcpscore,
      (
        SELECT MAX(num)
        FROM
          (SELECT num FROM quintiletable WHERE quintiletable.fid <= chained.fid)
      ) AS fidscore,
      (
        SELECT MAX(num)
        FROM
          (SELECT num FROM quintiletable WHERE quintiletable.inp <= chained.inp)
      ) AS inpscore,
      (
        SELECT MIN(num)
        FROM
          (
            SELECT num
            FROM quintiletable WHERE chained.load >= quintiletable.load
          )
      ) AS loadscore,
      (
        SELECT MIN(num)
        FROM
          (
            SELECT num
            FROM quintiletable WHERE chained.click >= quintiletable.click
          )
      ) AS clickscore,
      (
        SELECT MIN(num)
        FROM
          (
            SELECT num
            FROM quintiletable WHERE chained.reach >= quintiletable.reach
          )
      ) AS reachscore,
      (
        SELECT MIN(num)
        FROM
          (
            SELECT num
            FROM
              quintiletable
            WHERE chained.persistence >= quintiletable.persistence
          )
      ) AS persistencescore
    FROM (
      SELECT
        host,
        AVG(cls) AS cls,
        AVG(lcp) AS lcp,
        AVG(fid) AS fid,
        AVG(inp) AS inp,
        AVG(load) AS load,
        AVG(click) AS click,
        COUNTIF(chainlength = 1) AS reach,
        COUNTIF(chainlength = 7) AS persistence
      FROM chains
      WHERE
        (host = @url OR @url = "-")
        AND host IS NOT NULL
        AND host NOT LIKE "%.hlx.%"
        AND host != "localhost"
      GROUP BY host
      ORDER BY host DESC
    ) AS chained
  )
  WHERE
    host = @url OR (
      @url = "-"
      AND clsscore IS NOT NULL
      AND fidscore IS NOT NULL
      # AND inpscore IS NOT NULL
      AND lcpscore IS NOT NULL
      AND clickscore IS NOT NULL
      AND loadscore IS NOT NULL
      AND reachscore IS NOT NULL
      AND persistencescore IS NOT NULL
    )
)

#SELECT MIN(num) FROM (SELECT * FROM quintiletable WHERE 0.9841262752758466 >= quintiletable.click)
SELECT
  host,
  experiencescore,
  perfscore,
  audiencescore,
  engagementscore
FROM lookmeup
ORDER BY REGEXP_EXTRACT(host, r"\..*") ASC, host ASC
