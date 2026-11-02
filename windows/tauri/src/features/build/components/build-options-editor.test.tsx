import {afterEach,beforeEach,expect,mock,spyOn,test} from "bun:test";
import {act,type ChangeEvent,type ComponentProps} from "react";
import {createRoot,type Root} from "react-dom/client";
import * as input from "@/ui/input";
import * as virtualization from "@tanstack/react-virtual";
import {installHappyDom} from "@/test-utils/happy-dom";
import {LocaleProvider} from "@/i18n/locale-provider";
import {BuildOptionsEditor} from "./build-options-editor";
import {BuildWorkspaceController,type BuildEntry} from "../services/build-workspace-controller";
import {WindowsBuildProviderWorkspace} from "../services/build-provider-workspace";
import type {BuildOptionsResolution,BuildResolvedOption} from "@/platform/build-provider-platform";

let restore:()=>void,host:HTMLDivElement,root:Root;
const globalAct=globalThis as typeof globalThis & {IS_REACT_ACT_ENVIRONMENT?:boolean};let previous:boolean|undefined;
beforeEach(()=>{restore=installHappyDom();previous=globalAct.IS_REACT_ACT_ENVIRONMENT;globalAct.IS_REACT_ACT_ENVIRONMENT=true;host=document.createElement("div");document.body.append(host);root=createRoot(host);});
afterEach(()=>{act(()=>root.unmount());host.remove();globalAct.IS_REACT_ACT_ENVIRONMENT=previous;restore();});
async function fixture(option:BuildResolvedOption) {
 const domain=new WindowsBuildProviderWorkspace("C:/fixture",{guard:()=>()=>{},translate:key=>key,core:async()=>{throw new Error("No Core operation");},
  tools:async()=>{throw new Error("No tool probe");},providers:{send:async()=>{throw new Error("No Provider");},stop:async()=>{}}});
 const entry:BuildEntry={id:"engine:app",pluginID:"dev.example.engine",buildSystemID:"engine",root:"app",displayName:"Engine",modelSource:"provider",options:{},optionFingerprint:"first",droppedOptions:[]};
 const resolution=():BuildOptionsResolution=>({options:[option],dropped:[],fingerprint:"first"});
 const save=mock(async(_entry:BuildEntry,_id:string,value:unknown)=>{option={...option,value};return resolution();});
 const controller=new BuildWorkspaceController("C:/fixture",{domain,guard:()=>()=>{},detect:async()=>({detection:{instances:[entry],rejected:[],shadowed:[]},plugins:[{manifest:{id:entry.pluginID}}],document:{version:1,systems:{}},optionsRevision:"native-revision"}),
  options:{resolve:async()=>resolution(),save}});
 await controller.refresh();await act(async()=>root.render(<LocaleProvider language="en-US"><BuildOptionsEditor controller={controller} entry={entry} revision={0}/></LocaleProvider>));
 return {controller,save,entry};
}
test("opening and cancelling Build edits never save; explicit Save uses the native owner",async()=>{
 const control=spyOn(input,"default").mockImplementation(((props:ComponentProps<typeof input.default>)=>{
  const {size:_size,variant:_variant,...rest}=props;return <input {...rest} onInput={event=>props.onChange?.(event as unknown as ChangeEvent<HTMLInputElement>)}/>;
 }) as unknown as typeof input.default);
 const f=await fixture({id:"label",displayName:"Label",kind:"text",scope:"instance",value:"original",source:"user",choices:[],allowCustom:false});
 try{expect(f.save).not.toHaveBeenCalled();const field=host.querySelector<HTMLInputElement>('input[aria-label="Label"]')!;
  act(()=>{field.value="draft";field.dispatchEvent(new Event("input",{bubbles:true}));});
  act(()=>Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(button=>button.textContent==="Cancel")!.click());
  expect(field.value).toBe("original");expect(f.save).not.toHaveBeenCalled();
  act(()=>{field.value="saved 雪";field.dispatchEvent(new Event("input",{bubbles:true}));});
  await act(async()=>{Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(button=>button.textContent==="Save")!.click();});
  expect(f.save.mock.calls[0]?.slice(1,3)).toEqual(["label","saved 雪"]);
 }finally{await f.controller.dispose();control.mockRestore();}
},5000);
test("a save conflict keeps the edited value and reports failure",async()=>{
 const f=await fixture({id:"offline",displayName:"Offline",kind:"boolean",value:true,source:"user",choices:[],allowCustom:false});
 try{const check=host.querySelector<HTMLInputElement>('input[type="checkbox"]')!;act(()=>check.click());
  f.save.mockImplementationOnce(async()=>{throw new Error("build.options.conflict");});
  await act(async()=>{Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(button=>button.textContent==="Save")!.click();});
  expect(check.checked).toBe(false);expect(host.querySelector('[role="alert"]')?.textContent).toContain("Build options changed");
 }finally{await f.controller.dispose();}
},5000);
test("hiding and reopening the Build pane retains its workspace-owned draft without saving",async()=>{
 const f=await fixture({id:"offline",displayName:"Offline",kind:"boolean",value:true,source:"user",choices:[],allowCustom:false});
 try{act(()=>host.querySelector<HTMLInputElement>('input[type="checkbox"]')!.click());
  act(()=>root.render(null));
  await act(async()=>root.render(<LocaleProvider language="en-US"><BuildOptionsEditor controller={f.controller} entry={f.entry} revision={0}/></LocaleProvider>));
  expect(host.querySelector<HTMLInputElement>('input[type="checkbox"]')?.checked).toBe(false);expect(f.save).not.toHaveBeenCalled();
  act(()=>Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(button=>button.textContent==="Cancel")!.click());
  expect(host.querySelector<HTMLInputElement>('input[type="checkbox"]')?.checked).toBe(true);expect(f.save).not.toHaveBeenCalled();
 }finally{await f.controller.dispose();}
},5000);
test("large model choice lists only mount visible rows and reset is an explicit native write",async()=>{
 const virtual=spyOn(virtualization,"useVirtualizer").mockImplementation(((options:{count:number})=>({getTotalSize:()=>options.count*28,
  getVirtualItems:()=>Array.from({length:Math.min(options.count,10)},(_,index)=>({index,key:index,start:index*28,size:28}))})) as unknown as typeof virtualization.useVirtualizer);
 const f=await fixture({id:"features",displayName:"Features",kind:"multiSelect",value:["feature-999"],source:"user",allowCustom:false,
  choices:Array.from({length:1000},(_,index)=>({value:`feature-${index}`,title:null}))});
 try{expect(host.querySelectorAll('input[type="checkbox"]')).toHaveLength(10);expect(f.save).not.toHaveBeenCalled();
  await act(async()=>{Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find(button=>button.textContent==="Use inherited value")!.click();});
  expect(f.save.mock.calls[0]?.slice(1,3)).toEqual(["features",null]);
 }finally{await f.controller.dispose();virtual.mockRestore();}
},5000);
