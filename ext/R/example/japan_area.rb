#
# From https://oku.edu.mie-u.ac.jp/~okumura/stat/100410a.html
#

require "R"

R.run

areaname = ["北海道","本州","四国","九州","沖縄"].to_ca
areasize = [83457,231113,18792,42191,2276].to_ca / 10000.0

R %{
  par(family="HiraKakuProN-W3")
  par(las=1)
  par(mgp=c(2,0.8,0))
  barplot(areasize, names.arg=areaname)
  axis(2, labels="面積 (万km^2)", at=20, hadj=0.3, padj=-1, tick=FALSE) 
}, :areasize=>areasize, :areaname=>areaname

gets

R {
  par :family=>"HiraKakuProN-W3"
  par :las=>1
  par :mgp=>[2,0.8,0]
  barplot areasize, "names.arg"=>areaname
  axis 2, :labels=>"面積 (万km^2)", :at=>20, :hadj=>0.3, :padj=>-1, :tick=>false 
}

gets
