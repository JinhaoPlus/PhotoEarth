// All geometry uses a 256 × 256 design space. No artwork or fonts are fetched.
function titleRandom(text) {
    let seed = 2166136261;
    for (const byte of new TextEncoder().encode(text.normalize("NFC"))) {
        seed = Math.imul(seed ^ byte, 16777619);
    }
    return () => {
        seed = (seed + 0x6d2b79f5) >>> 0;
        let mix = Math.imul(seed ^ (seed >>> 15), seed | 1);
        mix ^= mix + Math.imul(mix ^ (mix >>> 7), mix | 61);
        return ((mix ^ (mix >>> 14)) >>> 0) / 4294967296;
    };
}

function drawCover(canvas, genre, title) {
    const ctx = canvas.getContext("2d");
    const rng = titleRandom(genre + "\u0000" + title.trim());
    const between = (min, max) => min + rng() * (max - min);
    const pick = list => list[Math.floor(rng() * list.length)];
    const night = /\b(night|midnight|moon|dark)\b/i.test(title);
    const frost = /\b(snow|ice|winter|cold|fog)\b/i.test(title);
    ctx.save();
    ctx.setTransform(canvas.width / 256, 0, 0, canvas.height / 256, 0, 0);
    function gradient(x0, y0, x1, y1, colors) {
        const fill = ctx.createLinearGradient(x0, y0, x1, y1);
        colors.forEach((color, i) => fill.addColorStop(i / (colors.length - 1), color));
        return fill;
    }
    function rect(x, y, w, h, color) {
        ctx.fillStyle = color;
        ctx.fillRect(x, y, w, h);
    }
    function paper(colors) { rect(0, 0, 256, 256, gradient(10, 0, 176, 256, colors)); }
    function disk(x, y, radius, color) {
        ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2); ctx.fillStyle = color; ctx.fill();
    }
    function polygon(points, color) {
        ctx.beginPath();
        points.forEach(([x, y], i) => i ? ctx.lineTo(x, y) : ctx.moveTo(x, y));
        ctx.closePath(); ctx.fillStyle = color; ctx.fill();
    }
    function line(x, y, ex, ey, color, width) {
        ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(ex, ey);
        ctx.lineWidth = width; ctx.strokeStyle = color; ctx.stroke();
    }
    function glow(x, y, radius, color) {
        const fill = ctx.createRadialGradient(x, y, 0, x, y, radius);
        fill.addColorStop(0, color); fill.addColorStop(1, "transparent");
        rect(x - radius, y - radius, radius * 2, radius * 2, fill);
    }
    function mirror() { ctx.translate(256, 0); ctx.scale(-1, 1); }
    function ridge(y, amplitude, color) {
        const points = [[-5, 260]];
        const f = between(0.009, 0.022), p = between(0, 6.28);
        for (let x = -5; x <= 265; x += 5) {
            points.push([x, y + amplitude * (Math.sin(p + x * f) + 0.23 * Math.sin(x * f * 2.8 + p))]);
        }
        polygon([...points, [265, 260]], color);
    }

    if (genre === "quiet-moments") {
        const warm = !frost && rng() < 0.48;
        const colors = warm ? ["#edd5ad","#f5e3c7","#9bb5ac","#6d9994","#365d63"]
                            : ["#9abfc7","#f2e7d8","#b7cfd0","#89adb0","#517983"];
        paper(colors.slice(0, 2));
        const x = between(46, 212), y = between(39, 91);
        disk(x, y, between(18, 33), "#fff6da");
        if (frost) {
            for (let i=0; i<52; i++) disk(between(0,256),between(0,152),between(0.42,1.45),"#fffcf4b8");
        }
        ridge(between(112, 131), 12, colors[2]);
        ridge(between(137, 157), 17, colors[3]);
        ridge(between(162, 186), 14, colors[4]);
        const shore = between(179, 199);
        rect(0, shore, 256, 256 - shore, gradient(0, shore, 0, 256, [colors[2], colors[0]]));
        for (let i = 0; i < 50; i++) {
            const depth = rng();
            const xx = x + between(-1, 1) * (4 + depth * 28);
            rect(xx, shore + depth * (256 - shore), between(2, 9), 0.9, "#fffae1a0");
        }
    } else if (genre === "open-road") {
        const colors = night ? ["#171c40","#79647f","#f7a16f","#4d4967","#222b44","#e7ac91"]
            : pick([["#dd8c65","#ffdfa5","#fff0ae","#b87359","#77484a","#ffd789"],
                    ["#6baea4","#f6deaf","#ffdb9e","#839577","#385b58","#f0cc91"]]);
        paper(colors.slice(0, 2));
        if (rng() < 0.5) mirror();
        const h = between(89, 135), van = between(80, 178);
        disk(between(45, 201), h - between(18, 44), between(16, 31), colors[2]);
        if (night) {
            for (let i=0; i<36; i++) disk(between(0,256),between(0,h*0.72),between(0.4,1.1),"#f6dda9ba");
        }
        ridge(h, 10, colors[3]);
        const road = [];
        const bends = between(25, 71);
        for (let i = 0; i <= 96; i++) {
            const t = i / 96;
            road.push([van + bends * Math.sin(t * 6) * t - 71 * t * t, h + (260 - h) * t, 2 + 91 * t * t]);
        }
        polygon([...road.map(([x,y,w]) => [x-w,y]), ...road.toReversed().map(([x,y,w]) => [x+w,y])], colors[4]);
        road.slice(1).forEach(([x,y], i) => {
            const [px,py] = road[i];
            if (Math.sin(32 * Math.log((i + 12) / 106)) > 0) line(px,py,x,y,colors[5],0.7 + 3*i/96);
        });
    } else if (genre === "piano") {
        const [light, shade, ink] = pick([
            ["#ffb4a2", "#ed817f", "#481d36"],
            ["#254d83", "#30275d", "#fff1cf"],
            ["#a9e8d0", "#65c5ba", "#103e41"],
            ["#ffd784", "#efab53", "#482b35"],
            ["#dfc1fb", "#ac98e7", "#362751"],
            ["#175c68", "#163e50", "#d9f7db"],
            ["#ffc1c7", "#ea8bae", "#501b45"],
            ["#bae9ff", "#84b7ef", "#183758"],
            ["#82445e", "#48314e", "#ffe4be"],
            ["#dae99a", "#a5cc7e", "#283d2a"],
        ]);
        paper([light, shade]);
        ctx.translate(128, between(119,139));
        ctx.rotate(between(-0.13,0.06));
        const spacing = between(15,19);
        for(let i=-2;i<=2;i++) line(-175,i*spacing,175,i*spacing,ink+"91",1.6);
        const count = Math.floor(between(4,7)), joined = Math.floor(between(0,count-1)), hollow = (joined+2)%count;
        const notes = Array.from({length:count}, (_,i)=>[
            -104+i*208/(count-1)+between(-4,4), (Math.floor(between(0,11))-5)*spacing/2
        ]);
        const width=spacing*1.43, height=spacing*0.93;
        const firstY=notes[joined][1], secondY=notes[joined+1][1];
        const pairDirection=firstY+secondY>=0 ? -1 : 1;
        const beamStart=(pairDirection<0 ? Math.min(firstY,secondY) : Math.max(firstY,secondY))+pairDirection*spacing*3;
        const slope=Math.min(5,Math.max(-5,(secondY-firstY)/4)), beam=[];
        notes.forEach(([x,y],i)=>{
            const paired=i===joined || i===joined+1;
            const dir=paired ? pairDirection : (y<0 ? 1 : -1);
            const stemX=x-dir*(width*0.46-1), tip=paired ? beamStart+(i===joined ? 0 : slope) : y+dir*spacing*3;
            line(stemX,y+dir*2,stemX,tip,ink,2.7);
            if(paired) beam.push([stemX,tip]);
            ctx.save();ctx.translate(x,y);ctx.rotate(-0.35);
            ctx.beginPath();ctx.ellipse(0,0,width/2,height/2,0,0,Math.PI*2);
            if(i===hollow){ctx.moveTo(width*0.30,0);ctx.ellipse(0,0,width*0.30,height*0.19,0,0,Math.PI*2);}
            ctx.fillStyle=ink;ctx.fill("evenodd");ctx.restore();
        });
        const dy=-pairDirection*spacing*0.38;
        polygon([beam[0],beam[1],[beam[1][0],beam[1][1]+dy],[beam[0][0],beam[0][1]+dy]],ink);
    } else if (genre === "jazz") {
        const [base,ink,accent,light] = night ? ["#182944","#e59164","#488b9a","#f2cd8a"] : pick([["#e6bb56","#202b35","#cc5538","#f2d9aa"],["#d86547","#242838","#e9b956","#f6d5ac"],["#7aa7a0","#1d2d3c","#da6845","#f5cf92"]]);
        paper([base,base]);
        if (rng()<0.5) mirror();
        ctx.translate(between(-12,26),between(-16,16));
        ctx.rotate(between(-0.15,0.1));
        const cx = between(70,119), cy = between(83,132);
        ctx.strokeStyle=ink; ctx.lineWidth=between(34,49); ctx.lineCap="butt";
        ctx.beginPath(); ctx.arc(cx,cy,83,Math.PI*0.09,Math.PI*1.55); ctx.stroke();
        if (/barriers|static|bar|stretch/i.test(title)) {
            for(let i=0;i<4;i++) polygon([[12+i*43,52-i*7],[31+i*43,47-i*7],[79+i*43,209],[56+i*43,217]],i%2 ? light : accent);
        } else polygon([[cx-8,cy+14],[262,between(3,48)],[172,cy+83]],accent);
        const spotX = between(136,189), spotY=between(40,69);
        disk(spotX,spotY,between(18,34),light);
        for(let i=0;i<4;i++) line(115+i*9,166,81+i*9,261,ink,3.3);
        for(let i=0;i<5;i++) for(let j=0;j<4;j++) disk(203+i*6,187+j*7,1.65,ink);
    } else if (genre === "lofi") {
        const [wall,sky,light,frame] = pick([["#b57e86","#a9a6cb","#f7c6a1","#51475d"],["#b4a29a","#98b9b0","#ffddad","#475658"],["#9d91ac","#bba7cf","#f4c2b2","#524765"]]);
        paper([wall,light]);
        if (rng()<0.5) mirror();
        const x=between(42,70), y=between(22,53), w=between(119,151), h=between(115,149), skew=between(40,92);
        polygon([[x,y+h],[x+w,y+h],[x+w-skew,263],[x-skew,263]],gradient(0,y+h,0,260,[light,wall]));
        rect(x-6,y-6,w+12,h+13,frame);
        rect(x,y,w,h,gradient(x,y,x+w,y+h,[sky,light]));
        ctx.save();ctx.beginPath();ctx.rect(x,y,w,h);ctx.clip();
        disk(x+w*between(0.3,0.76),y+h*between(0.17,0.45),between(11,19),"#fff0d1");
        for(let i=0;i<w;i+=11) { const bh=between(9,37); rect(x+i,y+h-bh,12,bh,wall); }
        ctx.restore();
        rect(x+w*0.57,y,4,h,frame); rect(x,y+h*0.51,w,4,frame);
        line(x+w*0.57+2,y+h+8,x+w*0.57+2-skew,260,wall,4);
        rect(x-11,y+h+6,w+22,6,frame);
        if (/coffee|ramen|morning/i.test(title)) {
            const cx=x+w*0.27, bottom=y+h+5;
            ctx.strokeStyle=frame; ctx.lineWidth=3.5;
            ctx.beginPath(); ctx.ellipse(cx+13,bottom-12,7,6,0,0,Math.PI*2); ctx.stroke();
            polygon([[cx-14,bottom-21],[cx+13,bottom-21],[cx+10,bottom],[cx-9,bottom]],frame);
            line(cx-11,bottom-19,cx+10,bottom-19,light,1.5);
        } else if (/laundry|wire/i.test(title)) {
            ctx.beginPath(); ctx.moveTo(0,y+14);ctx.quadraticCurveTo(122,y+57,256,y+21);
            ctx.lineWidth=1.6;ctx.strokeStyle=frame;ctx.stroke();
            for(let i=0;i<4;i++){
                const xx=x+i*33, t=xx/256, yy=y+14+86*t-79*t*t;
                polygon([[xx,yy],[xx+22,yy+1],[xx+18,yy+18+i%2*7],[xx-3,yy+15]], i%2?light:wall);
            }
        }
    } else if (genre === "ambient") {
        const [ground,mist,veil] = pick([["#122d45","#83dace","#9396e8"],["#24203d","#b7a0df","#8bcfdb"],["#13323c","#9bd8a0","#82bdda"]]);
        paper([ground,"#172439"]);
        const phase=between(0,6.28), tilt=between(-45,45);
        ctx.globalCompositeOperation="screen";
        glow(between(25,215),between(60,200),148,veil+"88");
        // Stacked translucent contours tighten along the fold, creating a soft aurora.
        for(let i=0;i<140;i++) {
            const t=i/139; ctx.beginPath();
            for(let x=-4;x<=261;x+=3) {
                const y=57+132*t + Math.sin(x/57+phase+t*2.4)*(28+31*t) + (x/256-0.5)*tilt;
                if(x===-4) ctx.moveTo(x,y); else ctx.lineTo(x,y);
            }
            ctx.strokeStyle = i<70 ? veil : mist;
            ctx.globalAlpha = 0.055 + 0.32*Math.pow(t,5);
            ctx.lineWidth=2.1; ctx.stroke();
        }
        ctx.globalAlpha=1;ctx.globalCompositeOperation="source-over";
    } else if (genre === "cinematic") {
        const [sky,haze,far,near] = pick([["#334756","#ddc9a1","#7f8580","#182b33"],["#43394d","#e8b995","#917c78","#262634"],["#263f4d","#c4d9cc","#778c90","#172a36"]]);
        paper([sky,haze,haze]);
        if(rng()<0.5) mirror();
        const x=between(144,195), h=between(148,177);
        disk(x,h-between(57,96),between(15,30),"#fce8c1");
        ridge(h-17,11,far); ridge(h+15,19,sky);
        const top=between(18,65), w=between(81,111);
        polygon([[-6,268],[-6,top+34],[w-21,top],[w,top+3],[w-4,h+26],[w+22,268]],near);
        polygon([[w-21,top],[w,top+3],[w-4,h+26],[w-16,h+8]],far);
        polygon([[-6,255],[91,h+24],[179,h+13],[262,h+29],[262,266]],near);
        line(0,254,154,h+18,haze,1.2);
    } else if (genre === "synthwave") {
        const [sky,glowColor,pink,grid] = pick([["#201443","#923e81","#fa7494","#6fe6ed"],["#211b48","#794aa5","#fb689a","#bd9afe"],["#192349","#5d4a9c","#ef6b9f","#79d9e3"]]);
        if (/synth|computer|machine|electronic/i.test(title)) {
            paper([sky,glowColor,sky]);
            glow(174,102,130,pink+"62");
            const phase=between(-2,2), freq=between(2.4,4);
            for (let row=0;row<37;row++) {
                const points=[[-6,266]];
                for(let x=-6;x<265;x+=3) {
                    const envelope=Math.sin(Math.PI*Math.max(0,Math.min(1,x/256)));
                    const wave=(Math.sin(x/256*Math.PI*freq+phase+row*.063)+.37*Math.cos(x/22-row*.075))*envelope;
                    points.push([x,73+row*4.2-wave*30]);
                }
                const edge=points.slice(1);
                polygon([...points,[265,266]],sky);
                ctx.beginPath();edge.forEach(([x,y],i)=>i?ctx.lineTo(x,y):ctx.moveTo(x,y));
                ctx.strokeStyle=gradient(10,0,245,0,[pink,grid,"#e4b0ff"]);ctx.lineWidth=1.35;ctx.stroke();
            }
        } else {
            const van=between(77,185), h=between(135,162), r=between(43,63), cy=h-r*0.81;
            paper([sky,glowColor,sky]); glow(van,cy,r*1.75,pink+"88");
            ctx.save();ctx.beginPath();ctx.arc(van,cy,r,0,Math.PI*2);ctx.clip();
            const sun=gradient(0,cy-r,0,cy+r,["#ffe298","#ff978a",pink]);
            rect(van-r,cy-r,r*2,r*0.96,sun);
            for(let i=0;i<8;i++)rect(van-r,cy-r*0.04+i*r/8,r*2,r/8*(0.91-i*0.09),sun);
            ctx.restore();
            ridge(h,9,sky); rect(0,h+5,256,256-h,gradient(0,h,0,256,[sky,"#16162f"]));
            for(let i=-6;i<=6;i++) line(van,h+5,van+i*72,260,grid+"8c",1.15);
            for(const d of [4,9,17,29,48,76,110])line(0,h+d,256,h+d,grid+"b8",1.15);
        }
    } else if (genre === "chiptune") {
        const [sky,moon,mid,front,hi]=pick([["#24223d","#fcd48d","#806891","#41586e","#93d5be"],["#222640","#ffdc98","#ac7aa3","#365061","#8edbbb"],["#302342","#f3bb83","#a66d91","#5b4c79","#83d3c5"]]);
        paper([sky,sky]);
        const unit=8, mx=Math.floor(between(7,24)), my=Math.floor(between(5,13));
        const space = /asteroid|space|star|scroller/i.test(title);
        if (space) {
            for(let i=0;i<48;i++)rect(Math.floor(rng()*32)*unit,Math.floor(rng()*32)*unit,2.5,2.5,hi);
            const rock=["0011100","0111110","1111211","1112221","1122211","0111110","0011000"];
            for(const [ox,oy,sz] of [[4,3,6],[20,13,8],[11,23,4]]) rock.forEach((row,j)=>[...row].forEach((p,i)=>{
                if(p!=="0")rect(ox*unit+i*sz,oy*unit+j*sz,sz,sz,p==="2"?front:mid);
            }));
            const ship=["00100","01110","11111","10101"];
            ship.forEach((row,j)=>[...row].forEach((bit,i)=>{if(bit==="1")rect((mx-8+i)*unit,(my+10+j)*unit,unit,unit,moon);}));
        } else {
            const planet=["01110","11111","11111","11111","01110"];
            planet.forEach((row,j)=>[...row].forEach((bit,i)=>{if(bit==="1")rect((mx+i)*unit,(my+j)*unit,unit,unit,moon);}));
            for(let i=0;i<24;i++)rect(Math.floor(rng()*32)*unit,Math.floor(rng()*19)*unit,2,2,moon);
            const phase=between(0,7);
            for(let i=0;i<32;i++) {
                const skyline=Math.round(18+Math.sin(i/4+phase)*3+Math.sin(i/2)*2);
                const floor=Math.round(25+Math.sin(i/5+phase)*4);
                rect(i*unit,skyline*unit,unit,256,mid); rect(i*unit,floor*unit,unit,256,front);
                rect(i*unit,floor*unit,unit,unit,hi);
                if(i%3===0)rect(i*unit,(floor+2)*unit,unit,unit,sky);
            }
        }
    }
    ctx.restore();
}
