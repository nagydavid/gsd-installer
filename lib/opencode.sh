#!/usr/bin/env bash
# opencode.sh — OpenCode harness: GSD staging (upstream installer), additive
# opencode.jsonc integration, verification, scoped rollback.
# Never touches Copilot state; never overwrites existing routing/permissions.

GSD_PKG="@opengsd/gsd-core@latest"

opencode_install() {
  local cfg; cfg="$(opencode_config_dir)"
  mkdir -p "$cfg"
  local args=(npx -y "$GSD_PKG" --opencode --global)
  [[ -n "${OPENCODE_CONFIG_DIR:-}" ]] && args+=(--config-dir "$cfg")
  run "stage GSD Core for OpenCode (upstream installer)" bash -c "${args[*]} < /dev/null"
  manifest_record "$cfg" "$INSTALL_TS" staged "$cfg" ""
}

opencode_configure() {
  local cfg jsonc spec
  cfg="$(opencode_config_dir)"
  jsonc="$cfg/opencode.jsonc"
  if [[ ! -f "$jsonc" ]]; then
    warn "no opencode.jsonc at $jsonc — creating minimal one"
    $DRY_RUN && return 0
    echo '{}' > "$jsonc"
  fi
  backup_file "$cfg" "$jsonc"

  local spec_obj='{"setIfAbsent":[],"arrayAdd":[{"path":"plugins","value":"billion-context","match":"billion-context"}],"checkUnchanged":["agent","permission","permissions","providers"]}'
  # gsd MCP server entry (matches the upstream installer's own migration shape)
  spec_obj="$(node -e '
    const s=JSON.parse(process.argv[1]);
    s.setIfAbsent.push({path:"mcp.gsd",value:{command:["npx","-y","-p","@opengsd/gsd-core","gsd-mcp-server","--no-prompts"],enabled:true,type:"local"}});
    console.log(JSON.stringify(s));' "$spec_obj")"
  # lean-ctx MCP entry — only when the shared tool is actually installed; PATH-resolved command
  if tool_present lean-ctx; then
    spec_obj="$(node -e '
      const s=JSON.parse(process.argv[1]);
      s.setIfAbsent.push({path:"mcp.lean-ctx",value:{command:["lean-ctx","mcp"],enabled:true,type:"local"}});
      console.log(JSON.stringify(s));' "$spec_obj")"
  fi
  # billion-context only when installed
  if ! tool_present billion-context; then
    spec_obj="$(node -e 'const s=JSON.parse(process.argv[1]);s.arrayAdd=[];console.log(JSON.stringify(s))' "$spec_obj")"
  fi

  local res
  res="$(jsonc_merge "$jsonc" "$spec_obj")"
  echo "$res" | node -e '
    const r=JSON.parse(require("fs").readFileSync(0,"utf8"));
    for(const a of r.actions) console.log("  [jsonc] "+a);
    if(!r.unchangedOk){console.error("  preservation check FAILED — file NOT written");process.exit(1)}
  ' || die "opencode.jsonc merge failed"
  log "opencode.jsonc integration configured (existing routing/permissions preserved)."
}

opencode_verify() {
  local cfg; cfg="$(opencode_config_dir)"
  section "OpenCode verification"
  local ok=true
  [[ -d "$cfg/gsd-core" ]] && log "  gsd-core staged: yes" || { log "  gsd-core staged: MISSING"; ok=false; }
  local agents; agents=$(find "$cfg/agents" -maxdepth 1 -name 'gsd-*' 2>/dev/null | wc -l)
  log "  GSD agent files: $agents"
  (( agents > 0 )) || ok=false
  node -e '
    const fs=require("fs");
    const s=fs.readFileSync(process.argv[1],"utf8");
    const strip=(x)=>{let o="",i=0,q=false,e=false;while(i<x.length){const c=x[i],n=x[i+1];
      if(q){o+=c;if(e){e=false;i++;continue}if(c==="\\"){e=true;i++;continue}if(c==="\"")q=false;i++;continue}
      if(c==="\""){q=true;o+=c;i++;continue}
      if(c==="/"&&n==="/"){while(i<x.length&&x[i]!=="\n")i++;continue}
      if(c==="/"&&n==="*"){i+=2;while(i<x.length&&!(x[i]==="*"&&x[i+1]==="/"))i++;i+=2;continue}
      o+=c;i++}
      return o.replace(/,(\s*[}\]])/g,"$1")};
    const o=JSON.parse(strip(s));
    const plugins=o.plugins||o.plugin||[];
    const has=(arr,m)=>arr.some(x=>x===m||(x&&x.name===m));
    if(!has(plugins,"billion-context")){console.log("  billion-context plugin: MISSING");process.exit(1)}
    if(!o.mcp||!o.mcp.gsd){console.log("  mcp.gsd: MISSING");process.exit(1)}
    console.log("  billion-context plugin: present");
    console.log("  mcp.gsd: present");
    console.log("  agent routing entries: "+Object.keys(o.agent||{}).length);
  ' "$cfg/opencode.jsonc" 2>/dev/null || ok=false
  if $ok; then log "  OpenCode verification: PASS"; else log "  OpenCode verification: FAIL"; return 1; fi
}

opencode_rollback() {
  local cfg; cfg="$(opencode_config_dir)"
  section "OpenCode rollback (Copilot state untouched)"
  local mf ts
  mf="$(manifest_path "$cfg")"; ts="$(manifest_latest_ts "$cfg")"
  if [[ -n "$ts" ]]; then
    # Restore the OLDEST backup per file across all recorded runs (true
    # pre-installer state — reruns back up already-modified files).
    node -e '
      const fs=require("fs");
      const mf=process.argv[1];
      const o=JSON.parse(fs.readFileSync(mf,"utf8"));
      const first={};
      for(const ts of Object.keys(o.runs).sort()){
        for(const e of o.runs[ts]||[]){
          if(e.kind==="backup"&&e.stored&&!first[e.file])first[e.file]=e.stored;
          if(e.kind==="created")first[e.file]="__created__";
        }
      }
      for(const [file,stored] of Object.entries(first)){
        if(stored==="__created__"){if(fs.existsSync(file)){fs.unlinkSync(file);console.log("  removed "+file)}}
        else if(fs.existsSync(stored)){fs.copyFileSync(stored,file);console.log("  restored "+file)}
      }
    ' "$mf"
  fi
  local args=(npx -y "$GSD_PKG" --opencode --global --uninstall)
  [[ -n "${OPENCODE_CONFIG_DIR:-}" ]] && args+=(--config-dir "$cfg")
  run "unstage GSD Core from OpenCode (upstream uninstaller)" bash -c "${args[*]} < /dev/null"
}
