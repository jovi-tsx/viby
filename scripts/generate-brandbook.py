#!/usr/bin/env python3
"""Build the Viby brandbook and vector/raster software applications (WSL).
Source content and palette: assets/branding/brandbook/*.json.
No runtime dependency, network transfer or original-logo modification.
"""
from pathlib import Path
from io import BytesIO
import csv, json, re, math, hashlib, html, colorsys, zipfile, tempfile
import xml.etree.ElementTree as ET
import cairosvg
from coloraide import Color as ColorScience
from fontTools.ttLib import TTFont as Font
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor, Color as RLColor
from reportlab.platypus import Paragraph
from reportlab.lib.styles import ParagraphStyle
from reportlab.graphics import renderPDF
from svglib.svglib import svg2rlg

ROOT=Path(__file__).resolve().parents[1]
B=ROOT/"assets/branding"
OUT=B/"brandbook"
TMP=Path(tempfile.gettempdir())/"viby-brandbook-fonts"
TMP.mkdir(parents=True,exist_ok=True)
DATA=json.loads((OUT/"content.json").read_text())
PALETTE=json.loads((OUT/"palette.json").read_text())
INK="#111713"; PAPER="#F4F7F2"; GREEN="#1DDD66"; DEEP="#136D3A"
MUTED="#4C5E52"; SURFACE="#19211C"; LINE="#CDD8CF"
NS="{http://www.w3.org/2000/svg}"
D=ET.parse(B/"viby-icon.svg").find(".//"+NS+"path").attrib["d"]
WAVE=re.split(r"\s(?=M)",D)[1]
FACES={}
for weight,name in [(450,"Body"),(550,"Medium"),(700,"Bold")]:
 f=Font(ROOT/"assets/fonts/manrope/Manrope-Variable.ttf",recalcTimestamp=False)
 f=instantiateVariableFont(f,{"wght":weight},inplace=True)
 # Static instances need distinct PostScript names; otherwise ReportLab
 # reuses one embedded face for all three weights.
 for record in list(f["name"].names):
  if record.nameID in {1,2,4,6}:
   label={1:"Manrope",2:name,4:f"Manrope {weight}",6:f"Manrope-Static{weight}"}[record.nameID]
   f["name"].setName(label,record.nameID,record.platformID,record.platEncID,record.langID)
 target=TMP/f"Manrope-{weight}.ttf";f.save(target)
 FACES[weight]=f
 pdfmetrics.registerFont(TTFont(name,str(target)))
pdfmetrics.registerFontFamily("Body",normal="Body",bold="Bold",italic="Body",boldItalic="Bold")
EXPORTED=[]

def rgb(h): return [int(h[i:i+2],16)/255 for i in (1,3,5)]
def luminance(h): return sum(w*(v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4) for w,v in zip([.2126,.7152,.0722],rgb(h)))
def ratio(a,b):
 x,y=sorted([luminance(a),luminance(b)]);return (y+.05)/(x+.05)
def foreground(bg): return INK if ratio(INK,bg)>=ratio(PAPER,bg) else PAPER

def text_svg(text,x,y,size=24,color=INK,weight=450,tracking=0):
 f=FACES[weight]; gs=f.getGlyphSet(); cmap=f.getBestCmap();scale=size/f["head"].unitsPerEm
 advance=0; paths=[]
 for ch in text:
  g=gs[cmap[ord(ch)]];pen=SVGPathPen(gs)
  g.draw(TransformPen(pen,(scale,0,0,-scale,x+advance,y)))
  paths.append(pen.getCommands());advance+=g.width*scale+tracking
 return f'<path fill="{color}" d="{" ".join(paths)}"/>'

def rect(x,y,w,h,fill,r=0,stroke=None):
 return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"'+(f' stroke="{stroke}" stroke-width="2"' if stroke else '')+'/>'

def mark(x,y,s,color=GREEN):
 return f'<path fill="{color}" fill-rule="evenodd" transform="translate({x} {y}) scale({s/1024})" d="{D}"/>'

def svg_inner(name):
 root=ET.parse(B/name).getroot()
 return "".join(ET.tostring(e,encoding="unicode") for e in root if e.tag not in {NS+"title",NS+"desc"})
LOCKUPS={name:svg_inner(name) for name in ["viby-lockup-ink.svg","viby-lockup-light.svg","viby-lockup-mono-ink.svg","viby-lockup-mono-light.svg"]}
def lockup(x,y,w=300,light=False,mono=False):
 name="viby-lockup-"+("mono-" if mono else "")+("light" if light else "ink")+".svg"
 return f'<g transform="translate({x} {y}) scale({w/720})">{LOCKUPS[name]}</g>'

def document(w,h,title,body):
 return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-labelledby="title"><title id="title">{html.escape(title)}</title>{body}</svg>'

def export(relative,w,h,title,body):
 target=OUT/relative;target.parent.mkdir(parents=True,exist_ok=True)
 svg=document(w,h,title,body)
 target.with_suffix(".svg").write_text(svg,encoding="utf8")
 cairosvg.svg2png(bytestring=svg.encode(),write_to=str(target.with_suffix(".png")),output_width=w,output_height=h)
 EXPORTED.extend([target.with_suffix(".svg"),target.with_suffix(".png")])

def wave_graphic(x,y,w,color,opacity=1):
 return f'<g opacity="{opacity}" transform="translate({x} {y}) scale({w/666}) translate(-113 -365)"><path fill="{color}" d="{WAVE}"/></g>'

def with_opacity(markup,value):
 # Per-path alpha survives SVG-to-PDF conversion; group opacity does not.
 return re.sub(r"<((?:[A-Za-z0-9_]+:)?path)\b",lambda m:"<"+m.group(1)+f' fill-opacity="{value}"',markup)

def watermark_art():
 for tone,light in [("ink",False),("light",True)]:
  export("watermarks/viby-watermark-"+tone,1200,400,"Viby — marca d’água transparente",with_opacity(lockup(0,0,1200,light,True),.12))
 body=rect(0,0,1600,1000,"#E5ECE5")+rect(225,65,1150,870,"#FFFFFF",16)
 body+=lockup(290,115,230)+text_svg("Notas de versão",290,295,54,INK,700)
 body+=text_svg("Pré-alpha · Exemplo editorial",292,350,24,DEEP)
 body+=rect(292,390,1018,2,LINE)
 for y,title,desc in [(465,"Identidade visual","Um sistema consistente para a presença do Viby."),(580,"Documentação","Orientações claras para usar e continuar o projeto."),(695,"Próximos passos","O roadmap funcional permanece separado da aplicação de marca.")]:
  body+=text_svg(title,292,y,29,INK,550)+text_svg(desc,292,y+44,22,MUTED)
 body+=with_opacity(lockup(900,785,370,False,True),.09)
 body+=text_svg("Aplicação de marca d’água / mockup editorial",292,885,18,MUTED)
 export("applications/viby-watermark-application",1600,1000,"Viby — marca d’água aplicada a documento",body)

def wallpapers():
 for tone,dark in [("dark",True),("paper",False)]:
  bg=INK if dark else PAPER; motif="#1C3526" if dark else "#D8F5E1"
  body=rect(0,0,3840,2160,bg)+wave_graphic(1500,465,2100,motif)
  body+=mark(3320,200,220)+lockup(3090,1830,550,dark)
  export("wallpapers/viby-wallpaper-"+tone+"-3840x2160",3840,2160,"Viby — wallpaper desktop "+tone,body)
  body=rect(0,0,1440,3120,bg)+wave_graphic(130,1290,1180,motif)
  body+=mark(1060,2380,180)
  export("wallpapers/viby-wallpaper-"+tone+"-1440x3120",1440,3120,"Viby — wallpaper vertical "+tone,body)

def application_art():
 body=rect(0,0,1600,1000,PAPER)
 body+=text_svg("Um símbolo. Diferentes escalas.",80,115,43,INK,700)
 x=90
 for size in [24,32,48,64,128,256]:
  body+=mark(x,365-size/2,size)+text_svg(str(size)+" px",x,560,22,MUTED);x+=size+105
 body+=rect(0,640,1600,360,INK)
 x=105
 for size in [24,32,48,64,128,256]:
  body+=mark(x,815-size/2,size);x+=size+105
 export("applications/viby-app-icon-sheet",1600,1000,"Viby — aplicação do app icon em diferentes tamanhos",body)
 # Desktop context and recording dock: synthetic, no actual user content.
 body=rect(0,0,1600,1000,"#DCE7DE")+wave_graphic(780,170,680,"#B8DCC2")
 body+=rect(105,85,1120,760,PAPER,18)+rect(105,85,1120,64,"#E5ECE5",18)
 body+=text_svg("Notas · exemplo de contexto",140,126,22,MUTED)+text_svg("Um espaço para suas ideias.",160,245,43,INK,700)
 for y,line in [(315,"Uma ideia por vez."),(375,"O trabalho continua no seu contexto."),(435,"A voz encontra espaço sem tomar a tela.")]:
  body+=text_svg(line,160,y,28,INK)
 body+=rect(160,480,3,38,DEEP)
 body+=rect(0,935,1600,65,"#19211C")
 for x in [655,720,785]:
  body+=rect(x,952,32,32,"#64756A",7)
 body+=mark(855,949,38)
 body+=rect(580,830,440,76,INK,38)
 heights=[15,26,35,17,45,27,53,32,18,38,56,35,20,44,31,18,47,26,37,18]
 for i,h in enumerate(heights):body+=rect(646+i*15,868-h/2,5,h,GREEN,2.5)
 body+=text_svg("Mockup conceitual",1260,65,19,DEEP)
 export("applications/viby-desktop-mock",1600,1000,"Viby — mockup conceitual de uso no desktop",body)
 # Future engine preferences: explicitly labeled.
 body=rect(0,0,1600,1000,"#DCE7DE")+rect(390,50,820,900,INK,20)
 body+=lockup(438,86,230,True)+text_svg("Suas preferências de ditado",445,202,23,"#AEBBB0")
 for top,title in [(240,"Ativação"),(425,"Áudio"),(610,"Motor local")]:
  body+=rect(432,top,736,160,SURFACE,16)+text_svg(title,458,top+40,25,PAPER,550)
 for top,label,value in [(240,"Atalho de ditado","Ctrl + Shift + Espaço"),(425,"Microfone","Padrão do sistema"),(610,"Endereço do serviço","http://127.0.0.1:8080")]:
  body+=text_svg(label,458,top+80,19,"#AEBBB0")
  body+=rect(458,top+98,681,43,INK,9,"#64756A")+text_svg(value,474,top+127,20,PAPER)
 body+=rect(927,822,240,58,GREEN,10)+text_svg("Salvar alterações",945,859,23,INK,550)
 body+=text_svg("CONCEITO · integração dinâmica ainda não implementada",444,920,17,"#AEBBB0")
 export("applications/viby-options-mock",1600,1000,"Viby — conceito de preferências com motor local",body)
 body=rect(0,0,1600,1000,"#DCE7DE")+wave_graphic(320,250,880,"#C6DECC")
 body+=rect(1010,570,380,190,SURFACE,14)
 body+=text_svg("Options…",1050,635,30,PAPER)+rect(1030,665,340,1,"#64756A")+text_svg("Close",1050,720,30,PAPER)
 body+=rect(0,850,1600,150,INK)+mark(1125,897,48)
 body+=text_svg("Viby",1106,808,20,INK,550)+text_svg("21:30",1400,931,26,PAPER)
 body+=text_svg("Aplicação conceitual · menu mínimo preservado",80,80,24,DEEP)
 export("applications/viby-tray-mock",1600,1000,"Viby — ícone e menu mínimo na barra de sistema",body)
 body=rect(0,0,1600,1000,"#E5ECE5")+rect(90,70,1420,860,"#FFFFFF",18)
 body+=rect(90,70,1420,80,INK,18)+text_svg("jovi-tsx / viby",140,124,28,PAPER,550)
 body+=text_svg("Code     Issues     Pull requests     Actions",140,200,22,MUTED)
 banner=svg_inner("viby-github-banner.svg")
 body+=f'<g transform="translate(140 245) scale(.825)">{banner}</g>'
 body+=text_svg("A Windows dictation bridge for your local AI.",140,735,32,INK,700)
 body+=text_svg("Development stage: pre-alpha",140,800,23,DEEP,550)
 body+=text_svg("Código aberto · versão 0.0.1 · mockup de apresentação",140,858,22,MUTED)
 export("applications/viby-github-mock",1600,1000,"Viby — aplicação de marca no repositório",body)
 body=rect(0,0,1600,1000,INK)+rect(280,160,1040,680,PAPER,18)
 body+=mark(340,230,215)+text_svg("Bem-vindo ao Viby",610,300,44,INK,700)
 for y,line in [(375,"Uma interface simples para o seu ditado local."),(430,"Viby cuida da interação no Windows."),(474,"Você opera o motor de IA compatível.")]:
  body+=text_svg(line,610,y,22,MUTED)
 body+=rect(1000,696,250,68,GREEN,12)+text_svg("Continuar",1052,740,26,INK,550)
 body+=text_svg("Cancelar",825,740,25,MUTED)
 body+=text_svg("CONCEITO · instalador futuro, não disponível na release 0.0.1",342,805,19,DEEP)
 export("applications/viby-installer-mock",1600,1000,"Viby — aplicação conceitual em instalador futuro",body)

# PDF helpers use a fixed 960 x 600 point editorial canvas.
PW,PH=960,600
C=None; PAGE=0; DARK=False
def color(h): return HexColor(h)
def box(x,y,w,h,fill,r=0,stroke=None):
 C.setFillColor(color(fill))
 if stroke:C.setStrokeColor(color(stroke));C.setLineWidth(.8)
 C.roundRect(x,y,w,h,r,fill=1,stroke=int(bool(stroke)))
def normalized(s): return s.translate(str.maketrans({"–":"-","—":"-","‑":"-"}))
def text(s,x,y,size=12,weight="Body",fill=None):
 s=normalized(s)
 C.setFillColor(color(fill or (PAPER if DARK else INK)));C.setFont(weight,size);C.drawString(x,y,s)
def para(s,x,y,w=400,size=12,fill=None,leading=None):
 style=ParagraphStyle("p",fontName="Body",fontSize=size,leading=leading or size*1.5,textColor=color(fill or ("#AEBBB0" if DARK else "#4C5E52")))
 value=html.escape(normalized(s)).replace("\n","<br/>")
 p=Paragraph(value,style);_,h=p.wrap(w,700);p.drawOn(C,x,y-h);return h
def lines(s,x,y,size=38,leading=None,fill=None,weight="Bold"):
 for i,line in enumerate(s.split("\n")):text(line,x,y-i*(leading or size*1.16),size,weight,fill)
def svg_file(path,x,y,w=None,h=None):
 drawing=svg2rlg(str(path))
 if drawing is None:raise ValueError(path)
 if w is None:w=h*drawing.width/drawing.height
 if h is None:h=w*drawing.height/drawing.width
 factor=min(w/drawing.width,h/drawing.height)
 C.saveState();C.translate(x+(w-drawing.width*factor)/2,y+(h-drawing.height*factor)/2)
 C.scale(factor,factor);renderPDF.draw(drawing,C,0,0);C.restoreState()
def mark_pdf(x,y,size,mono=None):
 svg=document(1024,1024,"Viby",mark(0,0,1024,mono or GREEN))
 dr=svg2rlg(BytesIO(svg.encode()));C.saveState();C.translate(x,y);C.scale(size/1024,size/1024);renderPDF.draw(dr,C,0,0);C.restoreState()
def begin(page,index,dark=False):
 global PAGE,DARK
 PAGE=index;DARK=dark
 box(0,0,PW,PH,INK if dark else PAPER)
 C.bookmarkPage("p"+str(index))
 C.addOutlineEntry(page["section"]+" / "+page["title"].replace("\n"," "), "p"+str(index),0,False)
 text("VIBY / "+page["section"].upper(),54,563,9,"Medium",GREEN if dark else DEEP)
 C.setStrokeColor(color("#35493B" if dark else LINE));C.setLineWidth(.6);C.line(54,42,906,42)
 text("Viby · Brandbook / Edição 01",54,24,8,"Body","#AEBBB0" if dark else MUTED)
 text(f"{index:02d} / 36",859,24,8,"Medium","#AEBBB0" if dark else MUTED)
def heading(page,w=852):
 lines(page["title"],54,502,36)
 n=len(page["title"].split("\n"));y=502-(n-1)*42-32
 if page.get("intro"):y-=para(page["intro"],54,y,w,12)+20
 return y
def footnote(page,x=54,y=74,w=852):
 if page.get("note"):para(page["note"],x,y,w,8.5,fill="#AEBBB0" if DARK else MUTED,leading=12)
def panel_items(items,y,columns=2):
 gap=34;cw=(852-gap*(columns-1))/columns
 rows=math.ceil(len(items)/columns);rh=min(140,(y-108)/max(rows,1))
 for idx,item in enumerate(items):
  col=idx%columns;row=idx//columns;x=54+col*(cw+gap);top=y-row*rh
  text(item[0],x,top,16,"Bold")
  para(item[1],x,top-24,cw,11.5)
def palette_page(page):
 fam=PALETTE["families"][page["family"]];cols=fam["colors"];heading(page)
 cw=852/len(cols)
 for i,c in enumerate(cols):
  x=54+i*cw;box(x,350,cw,92,c["hex"])
  text(str(c["level"]),x+10,413,10,"Bold",foreground(c["hex"]))
  text(c["hex"],x+8,366,8,"Medium",foreground(c["hex"]))
 headers=["Nível","HEX","RGB / 0–255","HSV / H° S% V%","OKLCH / L C h°"]
 xs=[54,118,240,421,656]
 for x,s in zip(xs,headers):text(s,x,320,9,"Bold",DEEP)
 for i,c in enumerate(cols):
  y=295-i*17
  vals=[str(c["level"]),c["hex"]," / ".join(map(str,c["rgb"])),
    f'{c["hsv"]["h"]:.1f}  {c["hsv"]["s"]:.1f}  {c["hsv"]["v"]:.1f}',
    f'{c["oklch"]["l"]:.3f}  {c["oklch"]["c"]:.3f}  {c["oklch"]["h"]:.1f}']
  for x,s in zip(xs,vals):text(s,x,y,9.5,"Body")
 text("L = luminosidade perceptual · C = croma · HSV V = valor/brilho",54,65,8.5,"Body",MUTED)
def artifact_page(page):
 # Wrap the narrow editorial column by actual font metrics.
 parts=[]
 for raw in page["title"].split("\n"):
  line=""
  for word in raw.split():
   candidate=(line+" "+word).strip()
   if line and pdfmetrics.stringWidth(candidate,"Bold",29)>228:
    parts.append(line);line=word
   else:line=candidate
  if line:parts.append(line)
 lines("\n".join(parts),54,499,29,35)
 intro_y=499-(len(parts)-1)*35-34
 para(page.get("intro",""),54,intro_y,228,11.5)
 svg_file(OUT/page["asset"],317,112,589,368)
 footnote(page,54,102,852)

def build_pdf():
 global C
 target=OUT/"viby-brandbook.pdf"
 C=canvas.Canvas(str(target),pagesize=(PW,PH),pageCompression=1,invariant=1)
 C.setTitle("Viby - Brandbook completo");C.setAuthor("Viby");C.setSubject("Estratégia, arquétipo, paleta e aplicações digitais")
 for index,page in enumerate(DATA["pages"],1):
  kind=page["kind"]
  dark=kind in {"cover","archetype","manifesto","motion"}
  begin(page,index,dark)
  if kind=="cover":
   lines(page["title"],54,417,72,76)
   para(page["text"],58,214,440,15,fill="#AEBBB0")
   mark_pdf(641,203,240)
   svg_file(B/"viby-wordmark-light.svg",646,90,230,115)
   text("BRANDBOOK",58,121,13,"Medium",GREEN);text(page["note"],58,88,10,"Body","#AEBBB0")
  elif kind=="contents":
   heading(page);ys=[345,275,205,135]
   targets=[3,10,26,34]
   for item,y,target_page in zip(page["items"],ys,targets):
    text(item[0],54,y,18,"Bold");text(item[1],824,y,12,"Medium",DEEP);para(item[2],54,y-22,680,11)
    C.linkRect("", "p"+str(target_page),(54,y-43,906,y+18),relative=0,thickness=0)
   footnote(page,54,72)
  elif kind=="platform":
   y=heading(page);panel_items(page["items"],y,2);footnote(page)
  elif kind=="cards":
   heading(page)
   for i,item in enumerate(page["items"]):
    x=54+i*292;box(x,130,268,226,"#E5ECE5",14)
    text(str(i+1).zfill(2),x+20,326,12,"Medium",DEEP)
    # two-line fit for short card headings
    h=para(item[0],x+20,299,226,16,fill=INK,leading=21)
    para(item[1],x+20,290-h,226,11,leading=16)
    para(item[2],x+20,174,226,9,fill=DEEP)
   footnote(page)
  elif kind=="archetype":
   lines(page["title"],54,486,52,58)
   para(page["intro"],54,369,820,14,fill="#AEBBB0")
   for i,item in enumerate(page["items"]):
    y=290-i*122;text(item[0],54,y,21,"Bold",GREEN)
    para(item[1],54,y-29,420,12,fill=PAPER);para(item[2],526,y-29,360,11,fill="#AEBBB0")
   footnote(page,54,74)
  elif kind=="pairs":
   y=heading(page)
   rh=(y-120)/4
   for i,item in enumerate(page["items"]):
    top=y-i*rh;text(item[0],54,top,17,"Bold",DEEP)
    para(item[1],250,top+2,300,11);para(item[2],600,top+2,300,10.5)
  elif kind=="manifesto":
   lines(page["title"],54,493,49,56)
   y=329
   for s in page["paragraphs"]:y-=para(s,58,y,760,16,fill=PAPER,leading=24)+23
   footnote(page,58,78)
  elif kind=="voice":
   y=heading(page);rh=(y-110)/5
   for i,item in enumerate(page["items"]):
    top=y-i*rh;text(item[0],54,top,13,"Bold",DEEP)
    para(item[1],240,top+4,420,12,fill=INK);para(item[2],703,top+4,198,9.5)
   footnote(page,54,76)
  elif kind=="flow":
   heading(page)
   for i,item in enumerate(page["items"]):
    x=54+i*218;box(x,185,194,185,"#E5ECE5",14)
    para(item[0],x+18,343,158,16,fill=INK,leading=22)
    para(item[1],x+18,277,158,11,leading=16)
    if i<3:text("→",x+199,277,17,"Medium",DEEP)
   footnote(page,54,112)
  elif kind=="logo":
   heading(page,w=430);mark_pdf(605,185,260)
   for i,item in enumerate(page["items"]):
    y=302-i*68;text(item[0],54,y,14,"Bold",DEEP);para(item[1],54,y-20,443,10.5)
   footnote(page)
  elif kind=="signatures":
   heading(page)
   box(54,170,405,200,"#FFFFFF",14);box(481,170,425,200,INK,14)
   svg_file(B/"viby-lockup-ink.svg",85,207,340,113)
   svg_file(B/"viby-lockup-light.svg",525,207,340,113)
   text("Assinatura em superfície clara",74,185,9,"Body",MUTED)
   text("Assinatura em superfície escura",501,185,9,"Body","#AEBBB0")
   footnote(page,54,109)
  elif kind=="clearspace":
   heading(page,w=470);mark_pdf(680,274,128)
   C.setStrokeColor(color(DEEP));C.setDash(3,3);C.rect(648,242,192,192,stroke=1,fill=0);C.setDash()
   text("S",736,445,12,"Medium",DEEP);text("S/4",838,260,10,"Medium",DEEP)
   for i,item in enumerate(page["items"]):
    y=297-i*63;text(item[0],54,y,14,"Bold",DEEP);para(item[1],190,y+2,390,11)
   footnote(page)
  elif kind=="misuse":
   y=heading(page);panel_items(page["items"],y-8,2)
   footnote(page,54,81)
  elif kind=="icon":
   heading(page);svg_file(OUT/"applications/viby-app-icon-sheet.svg",116,118,728,260);footnote(page,54,87)
  elif kind=="palette-overview":
   y=heading(page)
   colors=[GREEN,INK,"#D9991B","#DE6259","#3C8EC4"]
   for i,(fill,label) in enumerate(zip(colors,["Verde","Neutros","Atenção","Erro","Informação"])):
    x=54+i*174;box(x,218,155,135,fill,12);text(label,x+14,239,12,"Medium",foreground(fill))
   footnote(page,54,130)
  elif kind=="ramp":palette_page(page)
  elif kind=="contrast":
   heading(page)
   for i,pair in enumerate(PALETTE["contrast_pairs"]):
    y=330-i*27
    box(54,y-5,64,22,pair["background"],4);text("Aa",70,y,12,"Bold",pair["foreground"])
    text(pair["label"],138,y,10.5);text(f'{pair["ratio"]:.2f}:1',593,y,10.5,"Medium")
    label="Evitar para texto" if pair["use"]=="avoid" else ("Controles / grande" if pair["use"]=="nontext" else "Texto AA")
    text(label,710,y,9.5,"Medium",DEEP if pair["use"]!="avoid" else "#9D332E")
   footnote(page,54,91)
  elif kind=="semantic":
   heading(page)
   rolelabels={"canvas":"Fundo","surface":"Superfície","text":"Texto","muted":"Texto auxiliar","action":"Ação","action_text":"Texto da ação","action_hover":"Hover","focus":"Foco","error":"Erro","warning":"Atenção","information":"Informação","control_border":"Limite de controle"}
   for k,theme in enumerate(["dark","light"]):
    x=54+k*442;text("SUPERFÍCIE "+("ESCURA" if theme=="dark" else "CLARA"),x,345,12,"Bold",DEEP)
    for j,(role,value) in enumerate(PALETTE["semantic_map"][theme].items()):
     text(rolelabels[role],x,317-j*17,10);text(value,x+186,317-j*17,10,"Medium",DEEP)
   footnote(page,54,93)
  elif kind=="type":
   heading(page);text("Aa",625,267,155,"Medium",INK);text("á ã ç ê ó",614,197,30,"Body",DEEP)
   for i,item in enumerate(page["items"]):
    y=300-i*68;text(item[0],54,y,14,"Bold",DEEP);para(item[1],54,y-23,475,11)
   footnote(page)
  elif kind=="layout":
   y=heading(page);panel_items(page["items"],y,2)
  elif kind=="motion":
   y=heading(page);panel_items(page["items"],y,2)
   footnote(page,54,79)
  elif kind=="watermark-rules":
   y=heading(page);panel_items(page["items"],y,2);footnote(page,54,88)
  elif kind in {"watermark-mock","desktop","options","tray","github","installer"}:artifact_page(page)
  elif kind=="wallpaper":
   heading(page)
   svg_file(OUT/"wallpapers/viby-wallpaper-dark-3840x2160.svg",54,156,392,221)
   svg_file(OUT/"wallpapers/viby-wallpaper-paper-3840x2160.svg",514,156,392,221)
   text("Tinta / desktop",54,136,11,"Medium",DEEP);text("Papel / desktop",514,136,11,"Medium",DEEP)
   footnote(page,54,112)
  elif kind=="discovery":
   y=heading(page);panel_items(page["items"],y,2);footnote(page,54,83)
  elif kind=="handoff":
   y=heading(page);panel_items(page["items"],y-4,2);footnote(page,54,85)
  elif kind=="sources":
   y=heading(page);panel_items(page["items"],y,2)
   for i,source in enumerate(DATA["sources"]):
    text(source["label"],54,146-i*13,8.5,"Body",DEEP)
    C.linkURL(source["url"],(54,142-i*13,660,155-i*13),relative=0,thickness=0)
   footnote(page,54,70)
  else:raise ValueError(kind)
  C.showPage()
 C.save()
 EXPORTED.append(target)
 import pymupdf
 with pymupdf.open(target) as document_pdf:
  document_pdf[0].get_pixmap(matrix=pymupdf.Matrix(1.25,1.25),alpha=False).save(OUT/"viby-brandbook-preview.png")
 EXPORTED.append(OUT/"viby-brandbook-preview.png")
 return target

def palette_exports():
 # HEX is authoritative; descriptive formats are always recomputed.
 for family in PALETTE["families"].values():
  previous=2.0
  for entry in family["colors"]:
   measured=ColorScience(entry["hex"])
   if not measured.in_gamut("srgb"):raise ValueError("Color outside sRGB")
   channels=[round(v*255) for v in measured.convert("srgb").coords()]
   hsv=colorsys.rgb_to_hsv(*[v/255 for v in channels])
   lch=measured.convert("oklch").coords()
   if not lch[0]<previous:raise ValueError("Non-monotonic palette lightness")
   previous=lch[0]
   entry["rgb"]=channels
   entry["hsv"]={"h":round(hsv[0]*360,1),"s":round(hsv[1]*100,1),"v":round(hsv[2]*100,1)}
   entry["oklch"]={"l":round(lch[0],5),"c":round(lch[1],5),"h":round(lch[2],2)}
 (OUT/"palette.json").write_text(json.dumps(PALETTE,ensure_ascii=False,indent=2)+"\n")
 with (OUT/"palette.csv").open("w",newline="",encoding="utf8") as f:
  writer=csv.writer(f);writer.writerow(["family","level","hex","r","g","b","hsv_h","hsv_s_percent","hsv_v_percent","oklch_l","oklch_c","oklch_h"])
  for key,fam in PALETTE["families"].items():
   for c in fam["colors"]:writer.writerow([key,c["level"],c["hex"],*c["rgb"],*c["hsv"].values(),*c["oklch"].values()])
 css="/* Expanded Viby palette. Generated from palette.json. */\n:root {\n"
 for key,fam in PALETTE["families"].items():
  for c in fam["colors"]:css+=f'  --viby-{key}-{c["level"]}: {c["hex"].lower()};\n'
 (OUT/"palette.css").write_text(css+"}\n")

def main():
 palette_exports();watermark_art();wallpapers();application_art();target=build_pdf()
 manifest={"edition":"01","pages":36,"palette_colors":56,
  "original_icon_sha256":hashlib.sha256((B/"viby-icon.svg").read_bytes()).hexdigest(),
  "files":{p.relative_to(OUT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(EXPORTED)}}
 (OUT/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
 print(f"Created {target.relative_to(ROOT)}; {len(EXPORTED)-2} vector/raster application exports.")
if __name__=="__main__":main()
