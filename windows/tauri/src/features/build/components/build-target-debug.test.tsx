import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import * as dialogControl from "@/ui/dialog";
import { BuildTargetsList } from "./build-targets-list";
import { BuildWorkspaceController } from "../services/build-workspace-controller";
import { WindowsBuildProviderWorkspace } from "../services/build-provider-workspace";
import type { BuildModel } from "../services/build-provider-types";

let restore:()=>void,host:HTMLDivElement,root:Root,previous:boolean|undefined;
let restoreDialog:()=>void;
const environment=globalThis as typeof globalThis & {IS_REACT_ACT_ENVIRONMENT?:boolean};
beforeEach(()=>{restore=installHappyDom();previous=environment.IS_REACT_ACT_ENVIRONMENT;environment.IS_REACT_ACT_ENVIRONMENT=true;
  // Base UI captures DOM availability before this per-test document exists.
  // Keep the product's content/actions and isolate only the shared portal.
  const dialog=spyOn(dialogControl,"default").mockImplementation((({children,title,footer})=><div role="dialog">{title}{children}{footer}</div>) as typeof dialogControl.default);
  restoreDialog=()=>dialog.mockRestore();
  host=document.createElement("div");document.body.append(host);root=createRoot(host);});
afterEach(()=>{act(()=>root.unmount());host.remove();restoreDialog();environment.IS_REACT_ACT_ENVIRONMENT=previous;restore();});
async function fixture() {
  const domain=new WindowsBuildProviderWorkspace("C:/fixture",{guard:()=>()=>{},translate:key=>key,core:async()=>{throw new Error("No Core call");},
    tools:async()=>{throw new Error("No tool probe");},providers:{send:async()=>{throw new Error("No backend");},stop:async()=>{}}});
  const controller=new BuildWorkspaceController("C:/fixture",{domain,guard:()=>()=>{},detect:async()=>{throw new Error("No detection");}});
  const instance={pluginID:"dev.example.build",buildSystemID:"engine",root:".",options:{}};
  const model:BuildModel={projects:[{id:"project",name:"project",path:".",properties:{}}],targets:[{id:"target",projectID:"project",name:"Service",path:".",tags:["service"],properties:{}}],
    tasks:[],contentRoots:[],optionValues:{}};
  const manifest={buildSystems:[{id:"engine",run:[{id:"serve",name:"Serve",source:"provider",execution:"service",debug:{configurationType:"engine.remote"}}]}]};
  const run=spyOn(controller,"runTarget").mockImplementation(()=>({completion:Promise.resolve(),cancel:()=>{}}));
  await act(async()=>root.render(<LocaleProvider language="en-US"><BuildTargetsList controller={controller} instance={instance} model={model} manifest={manifest} projectID="project"/></LocaleProvider>));
  return{controller,run,instance};
}
test("connection Debug is an explicit confirmation and Cancel performs no save or launch",async()=>{
  const f=await fixture();
  try {
    await act(async()=>host.querySelector<HTMLButtonElement>('button[aria-label="Save and Debug"]')!.click());
    expect(f.run).not.toHaveBeenCalled();
    await act(async()=>Array.from(document.querySelectorAll<HTMLButtonElement>("button")).find(button=>button.textContent==="Cancel")!.click());
    expect(f.run).not.toHaveBeenCalled();
  } finally {f.run.mockRestore();await f.controller.dispose();}
},5000);
test("confirmed Debug retains the exact Provider target and invokes the controller's debug action",async()=>{
  const f=await fixture();
  try {
    await act(async()=>host.querySelector<HTMLButtonElement>('button[aria-label="Save and Debug"]')!.click());
    await act(async()=>Array.from(document.querySelectorAll<HTMLButtonElement>("button")).find(button=>button.textContent==="Save and Debug")!.click());
    expect(f.run).toHaveBeenCalledTimes(1);expect(f.run.mock.calls[0]?.[1]).toMatchObject({debugConfigurationType:"engine.remote",
      reference:{pluginID:"dev.example.build",root:".",projectID:"project",targetID:"target",run:"serve"}});
    expect(f.run.mock.calls[0]?.slice(2)).toEqual([[],true]);
  } finally {f.run.mockRestore();await f.controller.dispose();}
},5000);
