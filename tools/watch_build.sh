#!/bin/bash
# usage: tools/watch_build.sh <commit_sha>   (polls the GitHub Actions run, saves the job log to $LOG or ./job.log)
TOKEN=$(printf 'protocol=https\nhost=github.com\nusername=mihrapnidaapp\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')
API=https://api.github.com/repos/mihrapnidaapp/encore
sleep 30
for i in $(seq 1 160); do
  R=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/actions/runs?head_sha=$1&per_page=1")
  ST=$(echo "$R" | python -c "import sys,json;r=json.load(sys.stdin)['workflow_runs'];print((r[0]['status']+' '+str(r[0]['conclusion'])+' '+str(r[0]['id'])) if r else 'none')")
  set -- $1 ; case "$ST" in completed*) echo "$ST"; break;; esac
  sleep 15
done
RUN=$(echo $ST | awk '{print $3}')
JOB=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/actions/runs/$RUN/jobs" | python -c "import sys,json;print(json.load(sys.stdin)['jobs'][0]['id'])")
sleep 20; curl -sL -H "Authorization: Bearer $TOKEN" "$API/actions/jobs/$JOB/logs" > "${LOG:-job.log}"
grep -E "error:|BUILD FAILED|warning: .*Encore/|Encore.ipa|Process completed" "${LOG:-job.log}" | sed 's/^[0-9TZ:.-]* //' | sort -u | head -120
