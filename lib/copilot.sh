#!/usr/bin/env bash
# copilot.sh — GitHub Copilot CLI harness: GSD staging (upstream installer),
# independent integrations (mcp-config.json, RTK preToolUse hook, model
# routing in settings.json), verification, scoped rollback.
# Never touches OpenCode state.

copilot_install() {
  local cfg; cfg="$(copilot_config_dir)"
  mkdir -p "$cfg"
  local args=(npx -y "$GSD_PKG" --copilot --global)
  [[ -n "${COPILOT_CONFIG_DIR:-}${COPILOT_HOME:-}" ]] && args+=(--config-dir "$cfg")
  run "stage GSD Core for Copilot CLI (upstream installer)" bash -c "${args[*]} < /dev/null"
  manifest_record "$cfg" "$INSTALL_TS" staged "$cfg" ""
}

copilot_configure() {
  local cfg; cfg="$(copilot_config_dir)"

  # --- MCP registration (independent of OpenCode's mcp block) ---
  local mcp="$cfg/mcp-config.json"
  [[ -f "$mcp" ]] || { $DRY_RUN || echo '{"mcpServers":{}}' > "$mcp"; }
  backup_file "$cfg" "$mcp"
  if tool_present lean-ctx; then
    local lean_cmd
    lean_cmd="$(command -v lean-ctx 2>/dev/null || true)"
    [[ -z "$lean_cmd" ]] && lean_cmd="$(npm root -g 2>/dev/null || echo /usr/local/lib/node_modules)/lean-ctx-bin/bin/lean-ctx"
    jsonc_merge "$mcp" "$(node -e '
      const cmd=process.argv[1];
      console.log(JSON.stringify({setIfAbsent:[{path:"mcpServers.lean-ctx",value:{type:"local",command:cmd,args:["mcp"],tools:["*"]}}]}))' "$lean_cmd")" >/dev/null
    log "  mcp-config.json: lean-ctx registered ($lean_cmd; existing servers preserved)"
  fi

  # --- RTK preToolUse hook (Copilot CLI hook contract: ~/.copilot/hooks/*.json) ---
  if tool_present rtk; then
    local hooks_dir="$cfg/hooks" hook_file="$cfg/hooks/gsd-rtk.json"
    if grep -rlq "rtk hook copilot" "$hooks_dir" 2>/dev/null; then
      log "  RTK hook: already registered — skipping (no duplicate hooks)"
    else
      run "register RTK preToolUse hook" bash -c "mkdir -p '$hooks_dir' && cat > '$hook_file' <<EOF
{
  \"version\": 1,
  \"hooks\": {
    \"preToolUse\": [
      { \"type\": \"command\", \"exec\": \"rtk\", \"args\": [\"hook\", \"copilot\"], \"timeoutSec\": 30 }
    ]
  }
}
EOF"
      manifest_record "$cfg" "$INSTALL_TS" created "$hook_file" ""
    fi
  else
    warn "rtk not installed — Copilot RTK integration skipped."
  fi

  # --- Billion Context: no upstream Copilot integration exists. ---
  log "  Billion Context: OpenCode-only integration (no supported Copilot CLI plugin upstream) — documented, not forced."
}

copilot_verify() {
  local cfg; cfg="$(copilot_config_dir)"
  section "Copilot CLI verification"
  local ok=true
  [[ -d "$cfg/gsd-core" ]] && log "  gsd-core staged: yes" || { log "  gsd-core staged: MISSING"; ok=false; }
  if grep -qi "GSD" "$cfg/copilot-instructions.md" 2>/dev/null; then
    log "  copilot-instructions.md: GSD section present"
  else
    log "  copilot-instructions.md: GSD section MISSING"; ok=false
  fi
  node -e '
    const fs=require("fs");
    const strip=(x)=>{let o="",i=0,q=false,e=false;while(i<x.length){const c=x[i],n=x[i+1];
      if(q){o+=c;if(e){e=false;i++;continue}if(c==="\\"){e=true;i++;continue}if(c==="\"")q=false;i++;continue}
      if(c==="\""){q=true;o+=c;i++;continue}
      if(c==="/"&&n==="/"){while(i<x.length&&x[i]!=="\n")i++;continue}
      if(c==="/"&&n==="*"){i+=2;while(i<x.length&&!(x[i]==="*"&&x[i+1]==="/"))i++;i+=2;continue}
      o+=c;i++}
      return o.replace(/,(\s*[}\]])/g,"$1")};
    const cfg=process.argv[1];
    const load=(p)=>JSON.parse(strip(fs.readFileSync(p,"utf8")));
    const m=load(cfg+"/mcp-config.json");
    console.log("  mcp servers: "+Object.keys(m.mcpServers||{}).join(", "));
    try{
      const s=load(cfg+"/settings.json");
      const agents=Object.keys((s.subagents&&s.subagents.agents)||{});
      console.log("  settings: model="+(s.model||"(unset)")+" autoTier="+(s.autoTier||"(unset)")+" routed agents="+agents.length);
    }catch(e){console.log("  settings.json: "+e.message)}
    for(const f of fs.readdirSync(cfg+"/hooks")){
      const h=load(cfg+"/hooks/"+f);
      if(h.version!==1||!h.hooks)throw new Error("bad hook file "+f);
      if(JSON.stringify(h).includes("rtk"))console.log("  RTK hook registered: "+f);
    }
  ' "$cfg" 2>/dev/null || ok=false
  if $ok; then log "  Copilot verification: PASS"; else log "  Copilot verification: FAIL"; return 1; fi
}

copilot_rollback() {
  local cfg; cfg="$(copilot_config_dir)"
  section "Copilot CLI rollback (OpenCode state untouched)"
  local mf ts
  mf="$(manifest_path "$cfg")"; ts="$(manifest_latest_ts "$cfg")"
  if [[ -n "$ts" ]]; then
    # Restore the OLDEST backup per file across all recorded runs (true
    # pre-installer state); remove files the installer created.
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
  local args=(npx -y "$GSD_PKG" --copilot --global --uninstall)
  [[ -n "${COPILOT_CONFIG_DIR:-}${COPILOT_HOME:-}" ]] && args+=(--config-dir "$cfg")
  run "unstage GSD Core from Copilot CLI (upstream uninstaller)" bash -c "${args[*]} < /dev/null"
}
