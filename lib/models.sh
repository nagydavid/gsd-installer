#!/usr/bin/env bash
# models.sh — model discovery, official GitHub pricing retrieval, profile
# recommendation/application. OpenCode and Copilot recommendations are
# generated separately and never cross-applied.

PRICING_URL="https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing"

pricing_json() { # prints live pricing JSON (fetched) or bundled snapshot
  local live="/tmp/gsd-installer-pricing.json" html
  html="$(mktemp)"
  if curl -sfL --max-time 15 "$PRICING_URL" -o "$html" 2>/dev/null; then
    python3 "$INSTALLER_ROOT/lib/parse-pricing.py" "$html" "$live" 2>/dev/null || true
  fi
  rm -f "$html"
  if [[ -s "$live" ]]; then cat "$live"; else
    node -e 'const o=require(process.argv[1]);o.source="snapshot";console.log(JSON.stringify(o))' "$INSTALLER_ROOT/data/pricing-snapshot.json"
  fi
}

pick_model() { # <pricing-json> <category> <strategy:cheapest|median|flagship>
  node -e '
    const p=JSON.parse(process.argv[1]);
    const cat=process.argv[2].toLowerCase(), strat=process.argv[3];
    const ms=p.models.filter(m=>m.tier==="Default"&&m.category.toLowerCase()===cat);
    if(!ms.length){console.log("");process.exit(0)}
    ms.sort((a,b)=>a.input-b.input||a.model.localeCompare(b.model));
    const pick=strat==="cheapest"?ms[0]:strat==="flagship"?ms[ms.length-1]:ms[Math.floor((ms.length-1)/2)];
    console.log(pick.model);
  ' "$1" "$2" "$3"
}

profile_file() {
  if [[ "$PROFILE" == custom ]]; then echo "$PROFILE_FILE"; else echo "$INSTALLER_ROOT/profiles/$PROFILE.json"; fi
}

# ---------------------------------------------------------------- Copilot
copilot_models() {
  log "Copilot CLI: fetching official model pricing (GitHub docs)…"
  COPILOT_PRICING="$(pricing_json)"
  node -e '
    const p=JSON.parse(process.argv[1]);
    console.log(`  pricing source: ${p.source}  models: ${p.models.length}`);
  ' "$COPILOT_PRICING"
}

copilot_profile_plan() { # prints resolved plan JSON
  node -e '
    const fs=require("fs");
    const p=JSON.parse(process.argv[1]);
    const prof=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
    const strat=prof.selection||"median";
    const plan={profile:prof.name,default:{model:pick(p,prof.default.category,prof.default.selection||strat),autoTier:prof.default.autoTier},roles:{}};
    for(const [role,r] of Object.entries(prof.roles)){
      plan.roles[role]={category:r.category,effortLevel:r.effortLevel,model:pick(p,r.category,r.selection||strat)};
    }
    console.log(JSON.stringify(plan));
    function pick(pr,cat,strat){
      const ms=pr.models.filter(m=>m.tier==="Default"&&m.category.toLowerCase()===cat.toLowerCase());
      if(!ms.length)return null;
      ms.sort((a,b)=>a.input-b.input||a.model.localeCompare(b.model));
      const pick=strat==="cheapest"?ms[0]:strat==="flagship"?ms[ms.length-1]:ms[Math.floor((ms.length-1)/2)];
      return pick.model;
    }
  ' "$COPILOT_PRICING" "$(profile_file)"
}

copilot_recommend_profile() {
  [[ -z "$PROFILE" ]] && PROFILE=balanced
  local plan; plan="$(copilot_profile_plan)"
  log "Recommended Copilot profile: $PROFILE"
  node -e 'console.log(JSON.stringify(JSON.parse(process.argv[1]),null,2))' "$plan"
  log "Apply with: ./install.sh --harness copilot --profile $PROFILE --yes"
}

copilot_apply_profile() {
  local cfg plan
  cfg="$(copilot_config_dir)"
  plan="$(copilot_profile_plan)"
  section "Copilot model routing (profile: $PROFILE)"
  local def_model auto_tier
  def_model="$(node -e 'console.log(JSON.parse(process.argv[1]).default.model)' "$plan")"
  auto_tier="$(node -e 'console.log(JSON.parse(process.argv[1]).default.autoTier)' "$plan")"
  if [[ -z "$def_model" || "$def_model" == null ]]; then
    warn "Could not resolve a default model from pricing data — routing left unchanged."
    return 0
  fi
  if command -v copilot >/dev/null 2>&1; then
    run "set Copilot default model" copilot config model "$def_model"
    run "set Copilot auto routing tier" copilot config autoTier "$auto_tier"
  else
    warn "copilot binary unavailable — writing settings.json directly"
    if [[ ! -f "$cfg/settings.json" ]]; then
      $DRY_RUN && return 0
      echo '{}' > "$cfg/settings.json"
    fi
    backup_file "$cfg" "$cfg/settings.json"
    jsonc_merge "$cfg/settings.json" "$(node -e '
      const plan=JSON.parse(process.argv[1]);
      console.log(JSON.stringify({setIfAbsent:[{path:"model",value:plan.default.model},{path:"autoTier",value:plan.default.autoTier}]}))' "$plan")" >/dev/null
  fi
  # Per-GSD-role routing (subagents group is edited in settings.json directly —
  # `copilot config` refuses group keys). Additive: existing per-agent entries preserved.
  local settings="$cfg/settings.json"
  if [[ ! -f "$settings" ]] && $DRY_RUN; then return 0; fi
  backup_file "$cfg" "$settings"
  local spec
  spec="$(node -e '
    const plan=JSON.parse(process.argv[1]);
    const ops=[];
    for(const [role,r] of Object.entries(plan.roles)){
      if(!r.model)continue;
      ops.push({path:"subagents.agents."+role,value:{model:r.model,effortLevel:r.effortLevel}});
    }
    console.log(JSON.stringify({setIfAbsent:ops}));' "$plan")"
  jsonc_merge "$settings" "$spec" >/dev/null
  log "Copilot routing applied (default model: $def_model, autoTier: $auto_tier, ${PROFILE} role map)."
}

# ---------------------------------------------------------------- OpenCode
opencode_models() {
  section "OpenCode models"
  if command -v opencode >/dev/null 2>&1; then
    log "Available providers/models (opencode models):"
    opencode models 2>/dev/null | sed -n '1,12p' | sed 's/^/  /'
    log "  …"
  else
    warn "opencode binary unavailable — skipping model discovery."
    return 0
  fi
  log "Existing OpenCode model routing in opencode.jsonc is PRESERVED by this installer."
  log "Optional recommendations are provider-aware only (no GitHub Copilot pricing is assumed for other providers)."
  if $RECOMMEND_ONLY; then
    log "Recommendation: keep the current 35-agent routing map unless a provider/model has changed."
  fi
}
