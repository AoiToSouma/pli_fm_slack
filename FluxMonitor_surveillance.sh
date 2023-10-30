#!/bin/bash

WORK_DIR=$(cd $(dirname $0);pwd)
source $WORK_DIR/fm.conf

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
    #Current time
    exe_date=$(date +"%Y-%m-%d %T")
    dsp_date=$(date -d"${exe_date}" +"%Y-%m-%dT%T")
    #Get FluxMonitor JOB IDs
    job_ids="$(psql -d plugin_mainnet_db -t -c "SELECT id FROM jobs WHERE type = 'fluxmonitor';" 2> /dev/null)"

    for job_id in ${job_ids[@]}; do
        if [ "${job_name[${job_id}]}" = "" ]; then
            #Initializing time
            pre_det[${job_id}]="${exe_date}" #previous error polling time
            pre_rst[${job_id}]="${exe_date}" #previous round stagnation time
            pre_pnt[${job_id}]="${exe_date}" #previous periodic notice time
            #Get JOB name
            job_name[${job_id}]="$(psql -d plugin_mainnet_db -t -c "SELECT name FROM jobs WHERE pipeline_spec_id = '${job_id}';" 2> /dev/null)"
            #Get JOB round
            pre_job_round[${job_id}]="$(psql -d plugin_mainnet_db -t -c "SELECT MAX(id) FROM pipeline_runs WHERE pipeline_spec_id = '${job_id}';" 2> /dev/null)"
            #Send Messege
            post_to_slack "${dsp_date} : $MONITOR_NAME" "${job_name[${job_id}]}" "good" "Monitoring start." "job runs id : ${pre_job_round[${job_id}]}" "${exe_date}"
        fi

        #DB error detection
        if [ ${DB_ERROR_TIMER} != 0 ]; then
            #Elapsed time since last time
            elapsed_time=$(echo $(expr `date -d"${exe_date}" +%s` - `date -d"${pre_det[${job_id}]}" +%s`))
            if [ $(( elapsed_time )) -ge $(( DB_ERROR_TIMER )) ]; then
                #interval exceeded, get JOB ERROR
                job_spec_error="$(psql -d plugin_mainnet_db -t -c "SELECT description FROM job_spec_errors WHERE updated_at>='${pre_det[${job_id}]}' AND job_id= '${job_id}';" 2> /dev/null)"
                if [ "${job_spec_error}" != "" ]; then
                    #Send Messege
                    post_to_slack "${dsp_date} : $MONITOR_NAME" "${job_name[${job_id}]}" "warning" "Error occurred!!" "${job_spec_error}" "${exe_date}"
                fi
                #Last status update
                pre_det[${job_id}]="${exe_date}"
            fi
        fi

        #round stagnation
        if [ ${ROUND_STAGNATION_TIMER} != 0 ]; then
            #Elapsed time since last time
            elapsed_time=$(echo $(expr `date -d"${exe_date}" +%s` - `date -d"${pre_rst[${job_id}]}" +%s`))
            if [ $(( elapsed_time )) -ge $(( ROUND_STAGNATION_TIMER )) ]; then
                #interval exceeded, get JOB round
                job_round="$(psql -d plugin_mainnet_db -t -c "SELECT MAX(id) FROM pipeline_runs WHERE pipeline_spec_id = '${job_id}';" 2> /dev/null)"
                if [ $(( pre_job_round[${job_id}] )) -eq $(( job_round )) ]; then
                    #Send Messege
                    post_to_slack "${dsp_date} : $MONITOR_NAME" "${job_name[${job_id}]}" "danger" "JOB round is stagnant." "job runs id : ${job_round}" "${exe_date}"
                fi
                #Last status update
                pre_rst[${job_id}]="${exe_date}"
                pre_job_round[${job_id}]=${job_round}
            fi
        fi

        #Periodic job execution status notification
        if [ ${PERIODIC_NOTICE_TIMER} != 0 ]; then
            #Elapsed time since last time
            elapsed_time=$(echo $(expr `date -d"${exe_date}" +%s` - `date -d"${pre_pnt[${job_id}]}" +%s`))
            if [ $(( elapsed_time )) -ge $(( PERIODIC_NOTICE_TIMER )) ]; then
                #interval exceeded, get JOB round
                job_round="$(psql -d plugin_mainnet_db -t -c "SELECT MAX(id) FROM pipeline_runs WHERE pipeline_spec_id = '${job_id}';" 2> /dev/null)"
                #Send Messege
                post_to_slack "${dsp_date} : $MONITOR_NAME" "${job_name[${job_id}]}" "good" "Periodic notification" "job runs id : ${job_round}" "${exe_date}"
                #Last status update
                pre_pnt[${job_id}]="${exe_date}"
            fi
        fi
    done
    #Detect errors from log files
    if [ ${LOG_ERROR_TIMER} != 0 ]; then
        if [ "${pre_line}" = "" ]; then
            #inital
            pre_line=$(wc -l ${PLI_LOG_FILE} | awk '{print $1}')
            pre_let="${exe_date}"
        fi
        #Elapsed time since last time
        elapsed_time=$(echo $(expr `date -d"${exe_date}" +%s` - `date -d"${pre_let}" +%s`))
        if [ $(( elapsed_time )) -ge $(( LOG_ERROR_TIMER )) ]; then
            #Dir check
            if [ ! -d $WORK_DIR ]; then
                mkdir $WORK_DIR
            fi
            #interval exceeded, get Error Log
            file_name=${WORK_DIR}/${ERR_LOG_PREFIX}$(date -d"${exe_date}" +%Y%m%d_%H%M%S).log
            cur_line=$(wc -l ${PLI_LOG_FILE} | awk '{print $1}')
            if [ $(( pre_line )) -gt $(( cur_line )) ]; then
                #Supports log rotation
                pre_line=1
            fi
            tail -n +"${pre_line}" ${PLI_LOG_FILE} | grep -e 'ERROR' -e 'fail' -e 'prefix' >${file_name}
            if [ ! -s $file_name ]; then
                #No errors detected
                rm ${file_name}
            else
                #Send Messege
                if "$LOG_ERROR_NOTICE" ; then
                    post_to_slack "${dsp_date} : $MONITOR_NAME" "${job_name[${job_id}]}" "danger" "Detect Error Log" "logfile : ${file_name}"
                fi
            fi
            pre_line=${cur_line}
            pre_let="${exe_date}"
        fi
    fi
    #Notify address balance
    if [ ${ADR_BLC_TIMER} != 0 ]; then
        if [ "${pre_abt}" = "" ]; then
	    #initial
	    pre_abt="${exe_date}"
        fi
	#Elapsed time since last time
        elapsed_time=$(echo $(expr `date -d"${exe_date}" +%s` - `date -d"${pre_abt}" +%s`))
	if [ $(( elapsed_time )) -ge $(( ADR_BLC_TIMER )) ]; then
	    plugin admin login -f ~/pluginV2/apicredentials.txt
	    node_balance_arr=()
	    IFS=$'\n' read -r -d '' -a node_balance_arr < <( plugin keys eth list | grep ETH: && printf '\0' )
	    node_balance_primary=$(echo ${node_balance_arr[0]} | sed s/ETH:[[:space:]]/''/)
	    if [ `echo "$node_balance_primary < $ADR_BLC_LIMIT" | bc` == 1 ]; then
                #Send Messege
	        post_to_slack "${dsp_date} : $MONITOR_NAME" "${job_name[${job_id}]}" "warn" "Address Balance" "${node_balance_primary}XDC"
	        pre_abt="${exe_date}"
	    fi
	fi
    fi
    sleep ${POLLING_INTERVAL}
done
