import { useEffect, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import type { BuildResolvedOption } from "@/platform/build-provider-platform";
import type { BuildEntry, BuildWorkspaceController } from "../services/build-workspace-controller";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import SettingsSelect from "@/ui/settings-select";
import { ScrollArea } from "@/ui/scroll-area";

function MultiChoice({ option, value, change }: {option:BuildResolvedOption;value:string[];change:(value:string[])=>void}) {
  const {t}=useTranslation(),viewport=useRef<HTMLDivElement>(null),[custom,setCustom]=useState("");
  const choices=[...option.choices];
  for(const selected of value) if(!choices.some(choice=>choice.value===selected)) choices.push({value:selected,title:null});
  const virtual=useVirtualizer({count:choices.length,getScrollElement:()=>viewport.current,estimateSize:()=>28,overscan:3});
  const row=(index:number)=>{const choice=choices[index]!; return <label key={choice.value} className="flex h-7 items-center gap-1 px-1 ui-text-sm">
    <input type="checkbox" checked={value.includes(choice.value)} onChange={()=>change(value.includes(choice.value)?value.filter(item=>item!==choice.value):[...value,choice.value])}/>
    <span className="truncate">{choice.title ?? choice.value}</span></label>;};
  return <><ScrollArea style={{height:Math.min(168,choices.length*28)}} viewportProps={{ref:viewport}}>
    {choices.length<=6?choices.map((_,index)=>row(index)):<div className="relative" style={{height:virtual.getTotalSize()}}>
      {virtual.getVirtualItems().map(item=><div key={item.key} className="absolute top-0 w-full" style={{transform:`translateY(${item.start}px)`}}>{row(item.index)}</div>)}
    </div>}
  </ScrollArea>{option.allowCustom?<div className="flex gap-1"><Input aria-label={t("build.options.custom")} value={custom} onChange={event=>setCustom(event.target.value)}/>
    <Button type="button" disabled={!custom || value.includes(custom)} onClick={()=>{change([...value,custom]);setCustom("");}}>{t("ui.add")}</Button></div>:null}</>;
}

/** The editor holds a draft. Only its explicit Save/Reset actions cross the
 * native persistence boundary; opening, hiding and cancellation never write. */
export function BuildOptionsEditor({controller,entry,revision}:{controller:BuildWorkspaceController;entry:BuildEntry;revision:number}) {
  const {t}=useTranslation(),[options,setOptions]=useState<BuildResolvedOption[]>([]),[selected,setSelected]=useState(""),
    [draft,setDraft]=useState<unknown>(),[error,setError]=useState<string>(),[busy,setBusy]=useState(false),[ready,setReady]=useState(false);
  const mounted=useRef(true),[retry,setRetry]=useState(0);
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  useEffect(()=>{let current=true;setReady(false);setError(undefined);
    void controller.resolveOptions(entry).then(result=>{if(!current)return;setOptions(result.options);setReady(true);
      setSelected(previous=>result.options.some(option=>option.id===previous)?previous:result.options[0]?.id??"");
    },()=>{if(current)setError(t("build.options.invalid"));});
    return()=>{current=false;};
  },[controller,entry,revision,retry,t]);
  const option=options.find(option=>option.id===selected);
  useEffect(()=>{setDraft(option?controller.optionDraft(entry,option.id)?.value??option.value:undefined);},[option,controller,entry]);
  const change=(value:unknown)=>{if(option)controller.editOptionDraft(entry,option.id,value);setDraft(value);};
  const save=async(value:unknown)=>{
    if(!option || !ready || busy)return;
    setBusy(true);setError(undefined);
    try{await controller.configureOption(entry,option.id,value,controller.optionDraft(entry,option.id)?.revision);if(mounted.current)setRetry(v=>v+1);}
    catch(cause){if(mounted.current)setError(cause instanceof Error && !cause.message.startsWith("build.options.")?cause.message:t("build.options.conflict"));}
    finally{if(mounted.current)setBusy(false);}
  };
  if(!controller.canConfigureOptions)return null;
  return <section aria-label={t("build.options.title")} className="mx-2 space-y-2 border-t border-border py-2">
    <div className="flex items-center gap-1"><span className="mr-auto ui-text-sm">{t("build.options.title")}</span><span className="ui-text-caption text-subtle-foreground">{t("build.options.local")}</span></div>
    {error?<div role="alert" className="ui-text-sm text-danger">{error}<Button variant="ghost" disabled={busy} onClick={()=>setRetry(value=>value+1)}>{t("build.window.detect")}</Button></div>:null}
    {option?<><SettingsSelect aria-label={t("build.options.option")} value={selected} options={options.map(option=>({value:option.id,label:option.displayName}))}
      disabled={busy || !ready} onChange={setSelected}/>
      <fieldset disabled={busy || !ready} className="space-y-1">
        {option.kind==="boolean"?<input aria-label={option.displayName} type="checkbox" checked={draft===true} onChange={event=>change(event.target.checked)}/>
        :option.kind==="multiSelect"?<MultiChoice option={option} value={Array.isArray(draft)?draft:[]} change={change}/>
        :option.kind==="singleSelect" && !option.allowCustom?<SettingsSelect value={typeof draft==="string"?draft:""} options={option.choices.map(choice=>({value:choice.value,label:choice.title??choice.value}))} onChange={change}/>
        :<Input aria-label={option.displayName} value={typeof draft==="string"?draft:""} onChange={event=>change(event.target.value)}/>}
      </fieldset>
      <div className="flex gap-1"><Button disabled={busy || !ready || draft===undefined} onClick={()=>void save(draft)}>{t("ui.save")}</Button>
        <Button variant="ghost" disabled={busy || !ready} onClick={()=>{controller.discardOptionDraft(entry,option.id);setDraft(option.value);}}>{t("ui.cancel")}</Button>
        <Button variant="ghost" disabled={busy || !ready} onClick={()=>void save(null)} tooltip={t("build.options.resetHint")}>{t("build.options.reset")}</Button></div>
    </>:null}
  </section>;
}
