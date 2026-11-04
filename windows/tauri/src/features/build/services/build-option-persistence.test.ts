import {expect,mock,test} from "bun:test";
import {BuildWorkspaceController,type BuildEntry} from "./build-workspace-controller";
import {WindowsBuildProviderWorkspace} from "./build-provider-workspace";
import type {BuildOptionsResolution,WindowsBuildCatalog} from "@/platform/build-provider-platform";

function deferred<T>() {let resolve!:(value:T)=>void;const promise=new Promise<T>(done=>{resolve=done;});return {promise,resolve};}
function fixture() {
  let generation=0,revision="first";
  const guard=()=>{const captured=generation;return ()=>{if(captured!==generation)throw new Error("revoked");};};
  const domain=new WindowsBuildProviderWorkspace("C:/fixture",{guard,core:async()=>{throw new Error("No tool operation expected");},
    tools:async()=>{throw new Error("No probe expected");},providers:{send:async()=>{throw new Error("No Provider expected");},stop:async()=>{}},translate:key=>key});
  const entry:BuildEntry={pluginID:"dev.example.engine",buildSystemID:"engine",id:"engine:app",root:"app",displayName:"Engine",modelSource:"provider",options:{strict:true},optionFingerprint:"old",droppedOptions:[]};
  const resolution:BuildOptionsResolution={options:[{id:"strict",displayName:"Strict",kind:"boolean",scope:"instance",value:true,source:"user",choices:[],allowCustom:false}],dropped:[],fingerprint:"resolved"};
  const save=mock(async (_entry:BuildEntry,_id:string,_value:unknown,_revision:string,_model:unknown,_signal:AbortSignal)=>{revision="second";return resolution;});
  const resolve=mock(async()=>resolution);
  const detect=mock(async():Promise<WindowsBuildCatalog>=>({detection:{instances:[entry],rejected:[],shadowed:[]},plugins:[{manifest:{id:entry.pluginID}}],document:{version:1,systems:{}},optionsRevision:revision}));
  const controller=new BuildWorkspaceController("C:/fixture",{domain,guard,detect,options:{resolve,save}});
  return {entry,resolution,controller,domain,save,resolve,detect,revoke:()=>{generation++;}};
}
test("UI and Agent option saves use the same native revision and refresh product facts without a tool process",async()=>{
  const f=fixture();try{await f.controller.refresh();expect(await f.controller.resolveOptions(f.entry)).toBe(f.resolution);
    await f.controller.configureOption(f.entry,"strict",false);
    expect(f.save).toHaveBeenCalledTimes(1);expect(f.save.mock.calls[0]?.slice(0,5)).toEqual([f.entry,"strict",false,"first",undefined]);
    expect(f.controller.snapshot().optionsRevision).toBe("second");expect(f.domain.operations()).toEqual([]);
    expect(f.detect).toHaveBeenCalledTimes(2);
  }finally{await f.controller.dispose();}
},5000);
test("an obsolete editor revision and concurrent save cannot overwrite newer configuration",async()=>{
  const f=fixture(),gate=deferred<BuildOptionsResolution>();
  try{await f.controller.refresh();await expect(f.controller.configureOption(f.entry,"strict",false,"obsolete")).rejects.toThrow("conflict");
    f.save.mockImplementationOnce(async()=>await gate.promise);
    const first=f.controller.configureOption(f.entry,"strict",false);
    await expect(f.controller.configureOption(f.entry,"strict",true)).rejects.toThrow("conflict");
    gate.resolve(f.resolution);await first;expect(f.save).toHaveBeenCalledTimes(1);
  }finally{gate.resolve(f.resolution);await f.controller.dispose();}
},5000);
test("closing the workspace aborts a pending save and drains its native acknowledgement",async()=>{
  const f=fixture(),entered=deferred<void>(),gate=deferred<BuildOptionsResolution>();let signal:AbortSignal|undefined;
  f.save.mockImplementationOnce(async(_entry,_id,_value,_revision,_model,token)=>{signal=token;entered.resolve();return await gate.promise;});
  try{await f.controller.refresh();const saving=f.controller.configureOption(f.entry,"strict",false);void saving.catch(()=>{});await entered.promise;
    let drained=false;const closing=f.controller.dispose().then(()=>{drained=true;});
    expect(signal?.aborted).toBe(true);expect(drained).toBe(false);gate.resolve(f.resolution);
    await expect(saving).rejects.toThrow();await closing;expect(f.detect).toHaveBeenCalledTimes(1);
  }finally{gate.resolve(f.resolution);await f.controller.dispose();}
},5000);
test("external source invalidation aborts the same pending write instead of reporting it saved",async()=>{
  const f=fixture(),gate=deferred<BuildOptionsResolution>();let signal:AbortSignal|undefined;
  f.save.mockImplementationOnce(async(_entry,_id,_value,_revision,_model,token)=>{signal=token;return await gate.promise;});
  try{await f.controller.refresh();const saving=f.controller.configureOption(f.entry,"strict",false);void saving.catch(()=>{});
    f.controller.filesChanged("C:/fixture/.lithe/build/options.json");expect(signal?.aborted).toBe(true);gate.resolve(f.resolution);
    await expect(saving).rejects.toThrow();expect(f.controller.snapshot().status).toBe("loading");
  }finally{gate.resolve(f.resolution);await f.controller.dispose();}
},5000);
test("revoked declarations cannot publish a delayed option read",async()=>{
  const f=fixture(),gate=deferred<BuildOptionsResolution>();f.resolve.mockImplementationOnce(async()=>await gate.promise);
  try{await f.controller.refresh();const reading=f.controller.resolveOptions(f.entry);void reading.catch(()=>{});f.revoke();gate.resolve(f.resolution);
    await expect(reading).rejects.toThrow("revoked");expect(f.save).not.toHaveBeenCalled();
  }finally{gate.resolve(f.resolution);await f.controller.dispose();}
},5000);
