#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Top-level fields:
#   schema: stable schema id.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   secondmate_guidance: return-channel action note for renderers and bearings.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.
EOF
}

case "${1:---json}" in
  --json) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

path_present_json() {  # <path>
  local present=0
  [ -e "$1" ] && present=1
  jq -n --arg path "$1" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

line_verb() {  # <line>
  local v=${1%%:*}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

line_note() {  # <line>
  local n
  case "$1" in
    *:*) n=${1#*:} ;;
    *) n=$1 ;;
  esac
  n="${n#"${n%%[![:space:]]*}"}"
  n="${n%"${n##*[![:space:]]}"}"
  printf '%s' "$n"
}

crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep
  raw=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" \
    '{state:$state,source:$source,detail:$detail,raw:$raw}'
}

status_event_json() {  # <status-log>
  local log=$1 present=0 raw='' verb='' note=''
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(line_verb "$raw")
    note=$(line_note "$raw")
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw}}'
}

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

runtime_metadata_json() {  # <worktree>
  local worktree=$1 source observed raw declared actual expected mtime now age stale_after status validation logs proof
  source="$worktree/.arena/worktree-runtime.json"
  observed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if [ ! -f "$source" ]; then
    jq -n --arg source "$source" --arg observed "$observed" \
      '{status:"absent",validation:"missing",observed_at:$observed,source:{path:$source,present:false}}'
    return 0
  fi
  raw=$(jq -c . "$source" 2>/dev/null) || {
    jq -n --arg source "$source" --arg observed "$observed" \
      '{status:"invalid",validation:"malformed",observed_at:$observed,source:{path:$source,present:true}}'
    return 0
  }
  if ! printf '%s' "$raw" | jq -e '
    def optional_type($key; $kind):
      (has($key) | not) or .[$key] == null or (.[$key] | type) == $kind;
    type == "object"
      and (.worktreePath | type) == "string"
      and optional_type("slug"; "string")
      and optional_type("apps"; "array")
      and optional_type("ports"; "object")
      and optional_type("urls"; "object")
      and optional_type("supabase"; "object")
      and optional_type("supabaseTarget"; "string")
      and optional_type("supabaseOwnership"; "string")
      and optional_type("supabaseStackId"; "string")
      and optional_type("logDirectory"; "string")
      and optional_type("logDir"; "string")
      and optional_type("proofDirectory"; "string")
      and optional_type("proofDir"; "string")
      and ((.supabase // {})
        | optional_type("target"; "string")
        and optional_type("ownership"; "string")
        and optional_type("stackId"; "string"))
  ' >/dev/null 2>&1; then
    jq -n --arg source "$source" --arg observed "$observed" \
      '{status:"invalid",validation:"schema",observed_at:$observed,source:{path:$source,present:true}}'
    return 0
  fi
  declared=$(printf '%s' "$raw" | jq -r '.worktreePath // empty' 2>/dev/null)
  expected=$(cd "$worktree" 2>/dev/null && pwd -P) || expected=$worktree
  actual=
  [ -z "$declared" ] || actual=$(cd "$declared" 2>/dev/null && pwd -P) || actual=
  if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
    jq -n --arg source "$source" --arg observed "$observed" --arg declared "$declared" --arg expected "$expected" \
      '{status:"invalid",validation:"mismatched",observed_at:$observed,source:{path:$source,present:true},worktree_path:{declared:($declared|if .=="" then null else . end),actual:$expected}}'
    return 0
  fi
  mtime=$(stat -c '%Y' "$source" 2>/dev/null || stat -f '%m' "$source" 2>/dev/null || printf 0)
  now=$(date +%s)
  stale_after=${FM_RUNTIME_METADATA_STALE_SECONDS:-86400}
  case "$mtime:$stale_after" in
    *[!0-9:]*|:*) age=0; status=invalid; validation=malformed ;;
    *)
      age=$((now - mtime))
      if [ "$age" -gt "$stale_after" ]; then status=stale; else status=valid; fi
      validation=valid
      ;;
  esac
  logs=$(printf '%s' "$raw" | jq -r '.logDirectory // .logDir // empty' 2>/dev/null)
  [ -n "$logs" ] || [ ! -d "$worktree/.arena/dev-logs" ] || logs="$worktree/.arena/dev-logs"
  proof=$(printf '%s' "$raw" | jq -r '.proofDirectory // .proofDir // empty' 2>/dev/null)
  case "$logs" in ''|/*) : ;; *) logs="$worktree/$logs" ;; esac
  case "$proof" in ''|/*) : ;; *) proof="$worktree/$proof" ;; esac
  jq -n \
    --argjson document "$raw" \
    --arg status "$status" \
    --arg validation "$validation" \
    --arg source "$source" \
    --arg observed "$observed" \
    --arg worktree "$expected" \
    --arg logs "$logs" \
    --arg proof "$proof" \
    --argjson mtime "$mtime" \
    --argjson age "$age" \
    '{
      status:$status,
      validation:$validation,
      observed_at:$observed,
      source:{path:$source,present:true,mtime_epoch:$mtime,age_seconds:$age},
      schema:($document.schemaVersion // $document.schema // null),
      worktree_path:{declared:$document.worktreePath,actual:$worktree},
      slug:($document.slug // null),
      apps:($document.apps // []),
      ports:($document.ports // {}),
      urls:($document.urls // {}),
      supabase:{
        target:($document.supabase.target // $document.supabaseTarget // null),
        ownership:($document.supabase.ownership // $document.supabaseOwnership // null),
        stack_id:($document.supabase.stackId // $document.supabaseStackId // null)
      },
      proof_directory:($proof|if .=="" then null else . end),
      log_directory:($logs|if .=="" then null else . end)
    }'
}

backlog_json() {
  if [ ! -f "$BACKLOG" ]; then
    jq -n --arg path "$BACKLOG" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$BACKLOG" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | del(.section,.order)
  ' < "$BACKLOG"
}

task_json_lines() {
  local meta id kind harness mode yolo project worktree home projects backend target status_log report_path
  local pr pr_source event_json current_json endpoint_exists agent_alive meta_json status_json report_json worktree_json home_json runtime_json
  local herdr_layout herdr_session herdr_parent_workspace herdr_child_workspace herdr_tab herdr_pane herdr_parent_project
  local last_event_raw last_event_verb current_state pending_decision blocked_event report_present=0 pr_from_status

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    harness=$(meta_value "$meta" harness)
    mode=$(meta_value "$meta" mode)
    yolo=$(meta_value "$meta" yolo)
    project=$(meta_value "$meta" project)
    worktree=$(meta_value "$meta" worktree)
    home=$(meta_value "$meta" home)
    projects=$(meta_value "$meta" projects)
    herdr_layout=$(meta_value "$meta" herdr_layout)
    [ -n "$herdr_layout" ] || herdr_layout=legacy-tab
    herdr_session=$(meta_value "$meta" herdr_session)
    herdr_parent_workspace=$(meta_value "$meta" herdr_parent_workspace_id)
    herdr_child_workspace=$(meta_value "$meta" herdr_child_workspace_id)
    herdr_tab=$(meta_value "$meta" herdr_tab_id)
    herdr_pane=$(meta_value "$meta" herdr_pane_id)
    herdr_parent_project=$(meta_value "$meta" herdr_parent_project)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    status_log="$STATE/$id.status"
    report_path="$DATA/$id/report.md"
    pr=$(meta_value "$meta" pr)
    pr_source=meta
    if [ -z "$pr" ]; then
      pr_from_status=$(first_pr_url_in_file "$status_log" || true)
      pr=$pr_from_status
      pr_source=status_event
    fi
    if [ -z "$pr" ]; then
      pr_source=absent
    fi

    current_json=$(crew_state_json "$id")
    event_json=$(status_event_json "$status_log")
    last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
    last_event_verb=$(printf '%s' "$event_json" | jq -r '.last_event.state // ""')
    current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
    pending_decision=0
    blocked_event=0
    [ "$last_event_verb" = needs-decision ] && [ "$current_state" = parked ] && pending_decision=1
    [ "$last_event_verb" = blocked ] && [ "$current_state" = blocked ] && blocked_event=1

    endpoint_exists=null
    if [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
        endpoint_exists=true
      else
        endpoint_exists=false
      fi
    fi
    agent_alive=not_checked
    if [ "$kind" = secondmate ] && [ -n "$target" ]; then
      agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
    fi

    [ -f "$report_path" ] && report_present=1 || report_present=0
    meta_json=$(path_present_json "$meta")
    status_json=$event_json
    report_json=$(path_present_json "$report_path")
    if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$home" ]; then home_json=$(path_present_json "$home"); else home_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$worktree" ]; then runtime_json=$(runtime_metadata_json "$worktree"); else runtime_json=$(jq -n '{status:"absent",validation:"missing",observed_at:null,source:{path:null,present:false}}'); fi

    jq -n \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg harness "$harness" \
      --arg mode "$mode" \
      --arg yolo "$yolo" \
      --arg project "$project" \
      --arg worktree "$worktree" \
      --arg home "$home" \
      --arg projects "$projects" \
      --arg backend "$backend" \
      --arg target "$target" \
      --arg herdr_layout "$herdr_layout" \
      --arg herdr_session "$herdr_session" \
      --arg herdr_parent_workspace "$herdr_parent_workspace" \
      --arg herdr_child_workspace "$herdr_child_workspace" \
      --arg herdr_tab "$herdr_tab" \
      --arg herdr_pane "$herdr_pane" \
      --arg herdr_parent_project "$herdr_parent_project" \
      --arg pr "$pr" \
      --arg pr_source "$pr_source" \
      --arg agent_alive "$agent_alive" \
      --arg last_event_raw "$last_event_raw" \
      --argjson current_state "$current_json" \
      --argjson meta_path "$meta_json" \
      --argjson status_log "$status_json" \
      --argjson report "$report_json" \
      --argjson worktree_path "$worktree_json" \
      --argjson home_path "$home_json" \
      --argjson endpoint_exists "$endpoint_exists" \
      --argjson runtime "$runtime_json" \
      --argjson pending_decision "$(bool_json "$pending_decision")" \
      --argjson blocked_event "$(bool_json "$blocked_event")" \
      --argjson report_present "$(bool_json "$report_present")" \
      '{
        id:$id,
        kind:$kind,
        harness:($harness // ""),
        mode:($mode // ""),
        yolo:($yolo // ""),
        project:($project // ""),
        backend:$backend,
        paths:{
          meta:$meta_path,
          status_log:$status_log,
          worktree:$worktree_path,
          home:$home_path,
          report:$report
        },
        secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
        current_state:$current_state,
        endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive},
        presentation:{
          layout:(if $backend == "herdr" then $herdr_layout else null end),
          session:($herdr_session|if .=="" then null else . end),
          parent_workspace_id:($herdr_parent_workspace|if .=="" then null else . end),
          child_workspace_id:($herdr_child_workspace|if .=="" then null else . end),
          tab_id:($herdr_tab|if .=="" then null else . end),
          pane_id:($herdr_pane|if .=="" then null else . end),
          parent_project:($herdr_parent_project|if .=="" then null else . end)
        },
        runtime:$runtime,
        pr:{url:($pr | if . == "" then null else . end),source:$pr_source},
        hints:{
          pending_decision:$pending_decision,
          blocked_event:$blocked_event,
          scout_report_present:$report_present,
          last_event_text:$last_event_raw
        },
        actions:(
          if $kind == "secondmate" then
            {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
             watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
             return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
          else
            {watch:"bin/fm-peek.sh fm-\($id)",
             steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
             return_channel_note:null}
          end)
      }'
  done | jq -s 'sort_by(.id)'
}

scout_report_lines() {
  local report id
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | sort \
    | while IFS= read -r report; do
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path}'
    done \
    | jq -s 'sort_by(.id)'
}

BACKLOG_JSON=$(backlog_json)
TASKS_JSON=$(task_json_lines)
SCOUT_REPORTS_JSON=$(scout_report_lines)

jq -n \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --argjson backlog "$BACKLOG_JSON" \
  --argjson tasks "$TASKS_JSON" \
  --argjson scout_reports "$SCOUT_REPORTS_JSON" \
  'def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
     secondmate_guidance:{
       note:"For kind=secondmate, send marked supervisor requests with fm-send and read the status/doc return channel; do not routinely fm-peek the secondmate chat for answers."
     }
   }'
