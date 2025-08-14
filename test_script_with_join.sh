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
    
$docker_pfx psql --dbname $(get_db 'ekd_ekd') -c "SET search_path to public, ekd_ekd;
select
    employee.id,
    person.first_name,
    person.last_name,
    client_department.id,
    client_department.name,
    employee_position.name,
    permitted_client_department.employee_id
from ekd_id.person as person
join client_user on client_user.user_id=person.user_id
join employee on employee.client_user_id=client_user.id
join client_department on employee.client_department_id=client_department.id
join employee_position on employee.employee_position_id=employee_position.id
join permitted_client_department on employee.id=permitted_client_department.employee_id
where first_name='Алдар' and last_name='Босхомджиев'"