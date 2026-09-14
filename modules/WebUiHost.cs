using System;
using System.IO;
using System.Collections.Generic;
using System.Text.Json;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
public class StitchWebHost : WebView2 {
 public readonly Queue<string> Messages=new Queue<string>();
 public readonly Queue<string[]> DroppedFiles=new Queue<string[]>();
 public string Failure=""; public bool Loaded=false;
 public bool RequestWindowCommand(string action){
  if(action!="minimize"&&action!="maximize"&&action!="close")return false;
  BeginInvoke(new Action(()=>{
   var form=FindForm();if(form==null||form.IsDisposed)return;
   if(action=="minimize")form.WindowState=FormWindowState.Minimized;
   else if(action=="maximize")form.WindowState=form.WindowState==FormWindowState.Maximized?FormWindowState.Normal:FormWindowState.Maximized;
   else form.Close();
  }));
  return true;
 }
 private bool TryHandleWindowCommand(string json){
  JsonDocument document=null;
  try{
   document=JsonDocument.Parse(json);JsonElement action;
   return document.RootElement.TryGetProperty("action",out action)&&action.ValueKind==JsonValueKind.String&&RequestWindowCommand(action.GetString());
  }catch(JsonException){return false;}finally{if(document!=null)document.Dispose();}
 }
 public async void Start(string folder,string profile){
  try {
   var environment=await CoreWebView2Environment.CreateAsync(null,profile);
   await EnsureCoreWebView2Async(environment);
   ZoomFactor=1.00;
   CoreWebView2.Settings.AreDefaultContextMenusEnabled=false;
   CoreWebView2.Settings.AreDevToolsEnabled=false;
   CoreWebView2.Settings.AreHostObjectsAllowed=false;
   CoreWebView2.Settings.IsStatusBarEnabled=false;
   CoreWebView2.Settings.IsZoomControlEnabled=false;
   CoreWebView2.Settings.IsNonClientRegionSupportEnabled=true;
   CoreWebView2.SetVirtualHostNameToFolderMapping("pixflow.local",folder,CoreWebView2HostResourceAccessKind.DenyCors);
   CoreWebView2.NavigationStarting+=(s,e)=>{if(!e.Uri.StartsWith("https://pixflow.local/",StringComparison.Ordinal))e.Cancel=true;else Loaded=false;};
   CoreWebView2.NewWindowRequested+=(s,e)=>e.Handled=true;
   CoreWebView2.PermissionRequested+=(s,e)=>e.State=CoreWebView2PermissionState.Deny;
   CoreWebView2.WebMessageReceived+=(s,e)=>{if(e.Source.StartsWith("https://pixflow.local/",StringComparison.Ordinal)){
    if(TryHandleWindowCommand(e.WebMessageAsJson))return;
    if(e.AdditionalObjects!=null&&e.AdditionalObjects.Count>0){var files=new System.Collections.Generic.List<string>();foreach(var obj in e.AdditionalObjects){var file=obj as CoreWebView2File;if(file!=null)files.Add(file.Path);}DroppedFiles.Enqueue(files.ToArray());}
    Messages.Enqueue(e.WebMessageAsJson);
   }};
   CoreWebView2.NavigationCompleted+=(s,e)=>{Loaded=e.IsSuccess;if(!e.IsSuccess)Failure=e.WebErrorStatus.ToString();};
   CoreWebView2.Navigate("https://pixflow.local/index.html");
  }catch(Exception e){Failure=e.ToString();}
 }
 public void Send(string json){if(CoreWebView2!=null&&Loaded)CoreWebView2.PostWebMessageAsJson(json);}
 public async void CapturePage(string path){try{using(var stream=File.Create(path)){await CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png,stream);}Messages.Enqueue("{\"action\":\"captured\"}");}catch(Exception e){Failure=e.Message;}}
}


