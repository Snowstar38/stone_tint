--@ module = true
-- pixels is a packed RGBA byte string, row-major, top-to-bottom.
local byte, char, sub, concat = string.byte, string.char, string.sub, table.concat
local function fail(s) error(s, 0) end
local function u32(s,p) if p+3>#s then fail('truncated data') end return string.unpack('>I4',s,p) end
local function inflate(s)
 if #s<6 then fail('truncated zlib stream') end
 local cmf,flg=byte(s,1,2)
 if (cmf & 15)~=8 or (cmf>>4)>7 or ((cmf<<8)|flg)%31~=0 or (flg & 32)~=0 then fail('invalid zlib header') end
 local pos, bits, n = 3,0,0
 local function read(k)
  while n<k do if pos>#s-4 then fail('truncated deflate stream') end; bits=bits | (byte(s,pos)<<n); pos=pos+1; n=n+8 end
  local v=bits & ((1<<k)-1); bits=bits>>k; n=n-k; return v
 end
 local function tree(lengths, count)
  local counts, nextcode, tab = {},{},{}
  local max=0
  for i=1,count do local l=lengths[i] or 0; if l>0 then counts[l]=(counts[l] or 0)+1; if l>max then max=l end end end
  if max==0 then return {tab=tab,max=0} end
  local code=0
  for l=1,max do code=(code+(counts[l-1] or 0))<<1; nextcode[l]=code; if code+(counts[l] or 0)>1<<l then fail('invalid Huffman tree') end end
  for i=1,count do local l=lengths[i] or 0; if l>0 then
   local c=nextcode[l]; nextcode[l]=c+1; local rev=0
   for j=1,l do rev=(rev<<1)|(c&1); c=c>>1 end
   local step=1<<l; for j=rev,(1<<max)-1,step do tab[j]={i-1,l} end
  end end
  return {tab=tab,max=max}
 end
 local function symbol(t)
  if t.max==0 then fail('empty Huffman tree') end
  while n<t.max and pos<=#s-4 do bits=bits | (byte(s,pos)<<n); pos=pos+1; n=n+8 end
  local e=t.tab[bits & ((1<<t.max)-1)]
  if not e or e[2]>n then fail('invalid Huffman code') end
  bits=bits>>e[2]; n=n-e[2]; return e[1]
 end
 local fixedl,fixedd={},{}
 for i=0,287 do fixedl[i+1]=i<=143 and 8 or (i<=255 and 9 or (i<=279 and 7 or 8)) end
 for i=1,32 do fixedd[i]=5 end
 fixedl,fixedd=tree(fixedl,288),tree(fixedd,32)
 local lb={3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
 local le={0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
 local db={1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
 local de={0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
 local out, size={},0
 local last=0
 while last==0 do
  last=read(1); local typ=read(2)
  if typ==0 then
   local drop=n%8; read(drop); local len=read(16); local inv=read(16); if (len ~ inv)~=65535 then fail('invalid stored block') end
   for i=1,len do size=size+1; out[size]=read(8) end
  elseif typ==1 or typ==2 then
   local lt,dt=fixedl,fixedd
   if typ==2 then
    local hlit,hdist,hclen=read(5)+257,read(5)+1,read(4)+4
    if hlit>286 or hdist>32 then fail('invalid Huffman counts') end
    local order={16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
    local cl={}; for i=1,hclen do cl[order[i]+1]=read(3) end
    local ct=tree(cl,19); local lens={}; local k=1
    while k<=hlit+hdist do
     local v=symbol(ct)
     if v<=15 then lens[k]=v; k=k+1
     else
      local count, val
      if v==16 then if k==1 then fail('invalid repeat') end; count=read(2)+3; val=lens[k-1]
      elseif v==17 then count=read(3)+3; val=0
      elseif v==18 then count=read(7)+11; val=0 else fail('invalid code length') end
      if k+count-1>hlit+hdist then fail('invalid repeat') end
      for j=1,count do lens[k]=val; k=k+1 end
     end
    end
    local a,b={},{}; for i=1,hlit do a[i]=lens[i] end; for i=1,hdist do b[i]=lens[hlit+i] end
    if not a[257] or a[257]==0 then fail('missing end code') end
    lt,dt=tree(a,hlit),tree(b,hdist)
   end
   while true do
    local v=symbol(lt)
    if v<256 then size=size+1; out[size]=v
    elseif v==256 then break
    elseif v<=285 then
     local idx=v-256; local len=lb[idx]+read(le[idx]); local d=symbol(dt)+1
     if d>30 then fail('invalid distance') end
     local dist=db[d]+read(de[d]); if dist>size then fail('invalid distance') end
     for i=1,len do size=size+1; out[size]=out[size-dist] end
    else fail('invalid length') end
   end
  else fail('invalid deflate block') end
 end
 local chunks={}; for i=1,size,4096 do local t={}; for j=i,math.min(i+4095,size) do t[#t+1]=char(out[j]) end; chunks[#chunks+1]=concat(t) end
 return concat(chunks)
end
local function image(w,h,pixels)
 return {width=w,height=h,pixels=pixels,get=function(self,x,y)
  if type(x)~='number' or type(y)~='number' or x%1~=0 or y%1~=0 or x<0 or y<0 or x>=self.width or y>=self.height then return nil end
  return byte(self.pixels,(y*self.width+x)*4+1,(y*self.width+x)*4+4)
 end}
end
local function png(s)
 if type(s)~='string' or sub(s,1,8)~='\137PNG\r\n\26\n' then fail('invalid PNG signature') end
 local pos=9; local w,h,depth,ct,interlace; local ids={}; local palette,trans; local ended=false
 while pos<=#s do
  local len=u32(s,pos); if len>#s-pos-11 then fail('truncated PNG chunk') end
  local typ=sub(s,pos+4,pos+7); local data=sub(s,pos+8,pos+7+len); pos=pos+len+12
  if typ=='IHDR' then
   if w or len~=13 then fail('invalid IHDR') end
   w,h,depth,ct,_,_,interlace=string.unpack('>I4I4BBBBB',data)
   local valid=({[0]={[1]=true,[2]=true,[4]=true,[8]=true,[16]=true},[2]={[8]=true,[16]=true},[3]={[1]=true,[2]=true,[4]=true,[8]=true},[4]={[8]=true,[16]=true},[6]={[8]=true,[16]=true}})
   if w==0 or h==0 or not valid[ct] or not valid[ct][depth] or byte(data,11)~=0 or byte(data,12)~=0 or interlace>1 then fail('invalid PNG header') end
  elseif typ=='PLTE' then palette=data
  elseif typ=='tRNS' then trans=data
  elseif typ=='IDAT' then ids[#ids+1]=data
  elseif typ=='IEND' then ended=true; break end
 end
 if not w or not ended or #ids==0 then fail('incomplete PNG') end
 if ct==3 and (not palette or #palette%3~=0 or #palette==0) then fail('invalid palette') end
 local raw=inflate(concat(ids)); local rp=1; local channels=({[0]=1,[2]=3,[3]=1,[4]=2,[6]=4})[ct]
 local passes=interlace==0 and {{0,0,1,1}} or {{0,0,8,8},{4,0,8,8},{0,4,4,8},{2,0,4,4},{0,2,2,4},{1,0,2,2},{0,1,1,2}}
 local rows={}; for y=1,h do rows[y]={} end
 local tr1,tr2,tr3
 if trans and ct==0 then if #trans~=2 then fail('invalid transparency') end; tr1=string.unpack('>I2',trans)
 elseif trans and ct==2 then if #trans~=6 then fail('invalid transparency') end; tr1,tr2,tr3=string.unpack('>I2I2I2',trans) end
 for _,pass in ipairs(passes) do
  local sx,sy,dx,dy=table.unpack(pass); local pw=math.max(0,math.floor((w-sx+dx-1)/dx)); local ph=math.max(0,math.floor((h-sy+dy-1)/dy))
  if pw>0 and ph>0 then
   local stride=math.floor((pw*channels*depth+7)/8); local bpp=math.max(1,math.floor((channels*depth+7)/8)); local prev={}
   for py=0,ph-1 do
    if rp+stride>#raw then fail('truncated PNG pixels') end
    local filter=byte(raw,rp); rp=rp+1; if filter>4 then fail('invalid PNG filter') end
    local row={byte(raw,rp,rp+stride-1)}; rp=rp+stride
    for i=1,stride do
     local a=row[i-bpp] or 0; local b=prev[i] or 0; local c=prev[i-bpp] or 0; local p=0
     if filter==1 then p=a elseif filter==2 then p=b elseif filter==3 then p=(a+b)//2 elseif filter==4 then local v=a+b-c; local pa,pb,pc=math.abs(v-a),math.abs(v-b),math.abs(v-c); if pa<=pb and pa<=pc then p=a elseif pb<=pc then p=b else p=c end end
     row[i]=(row[i]+p)&255
    end
    local dst=rows[sy+py*dy+1]
    for x=0,pw-1 do
     local vals={}
     if depth<8 then local bit=x*depth; vals[1]=(row[bit//8+1]>>(8-depth-bit%8)) & ((1<<depth)-1)
     else local off=x*channels*(depth//8); for k=1,channels do local i=off+(k-1)*(depth//8)+1; vals[k]=depth==16 and (row[i]*256+row[i+1]) or row[i] end end
     local r,g,b,a
     local scale=depth==16 and 256 or 1
     if ct==0 then local v=vals[1]; r=depth<8 and v*255//((1<<depth)-1) or v//scale; g=r;b=r;a=(tr1==v) and 0 or 255
     elseif ct==2 then r=vals[1]//scale; g=vals[2]//scale; b=vals[3]//scale; a=(tr1==vals[1] and tr2==vals[2] and tr3==vals[3]) and 0 or 255
     elseif ct==3 then local idx=vals[1]; r,g,b=byte(palette,idx*3+1,idx*3+3); if not b then fail('palette index out of range') end; a=trans and byte(trans,idx+1) or 255
     elseif ct==4 then r=vals[1]//scale;g=r;b=r;a=vals[2]//scale
     else r=vals[1]//scale;g=vals[2]//scale;b=vals[3]//scale;a=vals[4]//scale end
     dst[sx+x*dx+1]=char(r,g,b,a)
    end
    prev=row
   end
  end
 end
 if rp~=#raw+1 then fail('invalid PNG pixel data length') end
 local result={}; for y=1,h do result[y]=concat(rows[y]) end
 return image(w,h,concat(result))
end
local function bmp(s)
 if type(s)~='string' or sub(s,1,2)~='BM' or #s<54 then fail('invalid BMP') end
 local offset=string.unpack('<I4',s,11); local hs=string.unpack('<I4',s,15)
 if hs<40 or 14+hs>#s then fail('unsupported BMP header') end
 local w,h,planes,bpp,compression=string.unpack('<i4i4I2I2I4',s,19)
 if w<=0 or h==0 or planes~=1 or (bpp~=8 and bpp~=24 and bpp~=32) or compression~=0 then fail('unsupported BMP format') end
 local height=math.abs(h); local stride=((w*bpp+31)//32)*4; if offset+stride*height>#s then fail('truncated BMP pixels') end
 local pal={}
 if bpp==8 then
  local used=string.unpack('<I4',s,47); if used==0 then used=256 end
  if used>256 or 14+hs+used*4>offset or offset>#s then fail('invalid BMP palette') end
  for i=0,used-1 do local b,g,r=byte(s,15+hs+i*4,17+hs+i*4); pal[i]=char(r,g,b,255) end
 end
 local rows={}
 for y=0,height-1 do local src=offset+(h>0 and height-1-y or y)*stride+1; local row={}
  for x=0,w-1 do
   if bpp==8 then local p=pal[byte(s,src+x)]; if not p then fail('palette index out of range') end; row[x+1]=p
   else local b,g,r=byte(s,src+x*(bpp//8),src+x*(bpp//8)+2); row[x+1]=char(r,g,b,255) end
  end
  rows[y+1]=concat(row)
 end
 return image(w,height,concat(rows))
end
local function safe(fn,...) local ok,a=pcall(fn,...); if ok then return a end; return nil,tostring(a) end
function decode_png(bytes) return safe(png,bytes) end
function decode_bmp(bytes) return safe(bmp,bytes) end
function decode_file(path)
 local ok, f, err=pcall(io.open,path,'rb'); if not ok then return nil,tostring(f) end; if not f then return nil,err end
 local success,data=pcall(function() return f:read('*a') end); f:close(); if not success or not data then return nil,tostring(data) end
 if sub(data,1,8)=='\137PNG\r\n\26\n' then return decode_png(data) elseif sub(data,1,2)=='BM' then return decode_bmp(data) end
 return nil,'unknown image signature'
end
-- Returns a row-major list of {r,g,b,a} tables.
function crop(img,x0,y0,w,h)
 local out={}; for y=y0,y0+h-1 do for x=x0,x0+w-1 do out[#out+1]={img:get(x,y)} end end; return out
end
return {decode_file=decode_file,decode_png=decode_png,decode_bmp=decode_bmp,crop=crop}

