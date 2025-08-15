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
    
$docker_pfx psql --dbname $(get_db 'ekd_ekd') -c "
select
    e.id,
    p.first_name,
    p.last_name,
    cd.id,
    cd.name,
    ep.name
from ekd_id.person as p
         join ekd_ekd.client_user as cu on cu.user_id=p.user_id
         join ekd_ekd.employee as e on e.client_user_id=cu.id
         join ekd_ekd.client_department as cd on e.client_department_id=cd.id
         join ekd_ekd.employee_position as ep on e.employee_position_id=ep.id
         join ekd_ekd.permitted_client_department as pcd on e.id=pcd.employee_id
where first_name='Алдар' and last_name='Босхомджиев'"
