#!/bin/bash

docker_pfx=""
if [[ -n "$(command -v docker)" ]] && [[ -n "$(docker container ls --format 'table {{.Names}}' 2>/dev/null | grep 'ekd-postgresql')" ]]; then
       docker_pfx="docker exec --user postgres ekd-postgresql"
fi

get_db() {
    local db_name=$1
    if [[ "$db_name" == 'ekd_file' ]]; then
            db_name='ekd_file_[^proc%]'
    fi

    result=$($docker_pfx psql -A -t -c "
    SELECT
        CASE
            WHEN datname ~ '_main' THEN datname
            ELSE (SELECT datname FROM pg_database WHERE datname ~ '_$db_name' LIMIT 1)
        END AS dn
    FROM pg_database
    WHERE (datname ~ '_main' OR datname ~ '_$db_name') AND datname IS NOT NULL AND datallowconn IS true LIMIT 1;")

    echo "$result"
}
    
$docker_pfx psql --dbname $(get_db 'ekd_id') -c "SET search_path to public, ekd_id;
select * from person as person
"
$docker_pfx psql --dbname ekd_metadata -c "SET search_path to public, ekd_metadata;
select *  from employee"