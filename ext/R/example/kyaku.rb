require "carray"

CA.gnuplot {
  terminal %{ wxt }
  (1..10).each do |n|
    x = CArray.double(1000000) {0}
    n.times do 
      x += CArray.double(1000000).random
    end
    x = x/n
    df = CADataFrame.new(:x=>x)
    h = df.histogram(:x, CA_DOUBLE(0..1,0.01))

    plot [h.x, h.count, nil, "boxes fill solid 0.5 noborder"], 
         :x=>[nil, 0..1],
         :title=>n.to_s,
         :nopause=>true

    sleep 0.5
  end
  gets
}