#!/bin/bash
#####     Edit to suit your environment     #####
#Slack Webhook URL
SLACK_WEBHOOK_URL="YOUR_WEBHOOK_URL"
#Monitoring interval time (s)
#監視間隔（秒）
POLLING_INTERVAL=120
####################################################

#Monitor Name
HOST_NAME=$(hostname -f)
IP_ADDRESS=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
MONITOR_NAME="${HOST_NAME}"_"${IP_ADDRESS}"

#---------------------------------------------
#  Post to Slack
#  $1 : text -> host_name
#  $2 : pretext -> job_name
#  $3 : color -> good/warning/danger
#  $4 : title -> detection type
#  $5 : text -> Job Spec ID
#  $6 : footer -> Detection date and time
#---------------------------------------------
post_to_slack(){
    MES_SLACK=$(jq -n --arg arg1 "$1" --arg arg2 "$2" --arg arg3 "$3" --arg arg4 "$4" --arg arg5 "$5" --arg arg6 "$6" '.text=$arg1 |.attachments[0].pretext=$arg2 | .attachments[0].color=$arg3 | .attachments[0].title=$arg4 | .attachments[0].text=$arg5 | .attachments[0].footer=$arg6 | .attachments[0].footer_icon="https://www.goplugin.co/assets/images/logo.png"')
    curl -X POST -H 'Content-type: application/json' --data "$MES_SLACK" $SLACK_WEBHOOK_URL 2> /dev/null
}

while true; do
    exe_date=$(date +"%Y-%m-%d %T")
    #Get FluxMonitor JOB IDs
    job_ids="$(psql -d plugin_mainnet_db -t -c "SELECT id FROM jobs WHERE type = 'fluxmonitor';" 2> /dev/null)"
    for job_id in ${job_ids[@]}; do
        if [ "${job_name[${job_id}]}" = "" ]; then
            job_name[${job_id}]="$(psql -d plugin_mainnet_db -t -c "SELECT name FROM jobs WHERE pipeline_spec_id = '${job_id}';" 2> /dev/null)"
        fi
        #Get the maximum value of JOB result ID
        execute_cnt="$(psql -d plugin_mainnet_db -t -c "SELECT MAX(id) FROM pipeline_runs WHERE pipeline_spec_id = '${job_id}';" 2> /dev/null)"
        if [ "${pre_exec_date}" != "" ]; then
            #Get JOB Error
            job_spec_error="$(psql -d plugin_mainnet_db -t -c "SELECT description FROM job_spec_errors WHERE updated_at>='${pre_exec_date}' AND job_id= '${job_id}';" 2> /dev/null)"
            if [ "${job_spec_error}" != "" ]; then
                #Send Messege
                post_to_slack "$MONITOR_NAME" "${job_name[${job_id}]}" "warning" "Error occurred!!" "${job_spec_error}" "${exe_date}"
            fi
        fi
        if [ "${pre_cnt[${job_id}]}" = "" ]; then
            #Initial processing
            job_status[${job_id}]="running"
            post_to_slack "$MONITOR_NAME" "${job_name[${job_id}]}" "good" "Monitoring start." "job runs id : ${execute_cnt}" "${exe_date}"
        elif [ ${pre_cnt[${job_id}]} -eq ${execute_cnt} ]; then
            #JOB stopped
            if [ ${job_status[${job_id}]} != "stopped" ]; then
                post_to_slack "$MONITOR_NAME" "${job_name[${job_id}]}" "danger" "Job Stopped!" "job runs id : ${execute_cnt}" "${exe_date}"
            fi
            job_status[${job_id}]="stopped"
        else
            #JOB Running
            if [ ${job_status[${job_id}]} != "running" ]; then
                post_to_slack "$MONITOR_NAME" "${job_name[${job_id}]}" "good" "Job Restarted!" "job runs id : ${execute_cnt}" "${exe_date}"
            fi
            job_status[${job_id}]="running" 
        fi
        pre_cnt[${job_id}]=${execute_cnt}
    done
    pre_exec_date="${exe_date}"
    sleep ${POLLING_INTERVAL}
done
