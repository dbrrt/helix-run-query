#!/bin/bash
QUERY=$1
PARAMS=$(cat src/queries/$QUERY.sql \
  | grep -e "--- [a-z]" \
  | sed 's/---//g' \
  | sed 's/^/  --parameter /' \
  | sed -E 's/: ([0-9]+)$/:INT64:\1/' \
  | sed -E 's/: ([0-9.]+)$/:FLOAT:\1/' \
  | sed -E 's/: (.*)/::"\1"/' \
  | tr -d '\n')

# if second argument starts with -- use that as the format (without the --)
# otherwise use the default format
FORMAT="--format=sparse"
if [[ $2 == --* ]]; then
  FORMAT="--format" $(echo $2 | sed 's/--//')
  shift
fi

# override --parameter domainkey::"..." with contents of DOMAINKEY env var
if [ -n "$DOMAINKEY" ]; then
  PARAMS=$(echo $PARAMS | sed -E "s/domainkey::\".*\"/domainkey::\"$DOMAINKEY\"/")
fi

# drop the first arg (query name)
shift
# override all other parameters with contents of command line args in the format parameter::value
while [ $# -gt 0 ]; do
  PARAMS=$(echo $PARAMS | sed -E "s/$1::\"[^\"]*\"/$1::\"$2\"/")
  shift
  shift
done

echo "cat src/queries/$QUERY.sql | bq query $PARAMS --use_legacy_sql=false $FORMAT" | sh


