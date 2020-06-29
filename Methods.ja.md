メソッドドキュメント
===================

マスクに関するメソッド
-------------------


* 一度生成されたマスク配列を取り除く方法は提供されていない。

== メソッド

=== --- CArray#has_mask?
マスク配列が付加されている場合にtrueを返す。
全要素がマスクされていなくても、マスク配列が付加されていればtrueを返す。

    a = CA_INT(0..2);
    a.has_mask?
    a[1] = UNDEF;
    a.has_mask?

=== --- CArray#any_masked?
マスクされた要素が１つ以上ある場合にtrueを返す。
どの要素もマスクされていない場合やマスク配列自体を持っていない場合にfalseを返す。

    a = CA_INT(0..2);
    a.mask = 0;
    a.any_masked?
    a[1] = UNDEF;
    a.any_masked?
    a.unmask;
    a.any_masked?

=== --- CArray#value
データ配列を参照する配列を返す。
マスクされているいないに関わらず、要素の値を参照したり、
値を変更することができる。
この配列（もしくはこの配列を参照する配列）に対し、
マスクを付加しようとすると例外が発生する。

    a = CA_INT(0..2);
    a[1] = UNDEF;
    a
    a.value

=== --- CArray#mask
マスク配列を参照するboolean型配列を返す。
この配列を変更すると、元の配列のマスク状態を変更することができる。
この配列（もしくはこの配列を参照する配列）に対し、
マスクを付加しようとすると例外が発生する。

    a = CA_INT(0..2);
    a[1] = UNDEF;
    a.mask
    a
    a.mask[] ^= 1;
    a

=== --- CArray#mask=(new_mask)
new_maskをマスク配列に代入する。
new_maskは、<TBD>でなければならない。
配列がマスク配列を持っていない場合は、代入前にマスク配列が生成される。

    a = CA_INT(0..2);
    a.mask
    a.mask = 0;
    a.mask
    a.mask = [0,1,0];
    a.mask
    a.mask ^= 1;
    a.mask

=== --- CArray#is_masked
マスク状態を表すboolean型配列を返す。
この配列はマスクされた要素が1で、マスクされていない要素が0となる。

    a = CA_INT(0..2);
    a[1] = UNDEF;
    a.is_masked

=== --- CArray#is_not_masked
マスク状態を表すboolean型配列を返す。
この配列はマスクされた要素が0で、マスクされていない要素が1となる。

    a = CA_INT(0..2);
    a[1] = UNDEF;
    a.is_not_masked

=== --- CArray#count_masked (*axis)
マスクされた要素の数を返す。
axisで与えられた次元で集計し、残りの次元の配列を返す。
axisが与えられない場合は、整数を返す。

    a = CA_INT(0..2);
    a[1] = UNDEF;
    a.count_masked

=== --- CArray#count_not_masked
マスクされていない要素の数を返す。
axisで与えられた次元で集計し、残りの次元の配列を返す。
axisが与えられない場合は、整数を返す。

    a = CA_INT(0..2);
    a[1] = UNDEF;
    a.count_not_masked

=== --- CArray#unmask([fill_value])
すべての要素のマスクを解除する。
fill_valueが与えられている場合は、マスクされた要素をすべてfill_valueで置き換える。
このメソッドでは、マスク配列自体を取り除かれることはない。

    a = CA_INT(0..2);
    # example for fill_value not to be given
    a[1] = UNDEF;
    a
    a.unmask();
    a
  
    # example for fill_value to be given
    b = CA_INT(0..2);
    b[1] = UNDEF;
    b.unmask(-9999);
    b

=== --- CArray#unmask_copy([fill_value])
すべての要素のマスクが解除された複製を返す。
fill_valueが与えられている場合は、マスクされた要素をすべてfill_valueで置き換える。
返り値の配列はマスク配列を持たない状態で生成される。

    a = CA_INT(0..2);
    a[1] = UNDEF;
    a

    b = a.unmask_copy(-9999)
    b.has_mask?

=== --- CArray#inherit_mask(a1, a2, ...)
オブジェクトと引数で与えられた配列の集合で(self,a1,a2,...)でマスク状態の論理和をとり、
新しいマスク状態として置き換える。

    a = CA_INT(0..2);
    b = CA_INT(0..2);
    c = CA_INT(0..2);
    a[0] = UNDEF;
    b[1] = UNDEF;
    c[2] = UNDEF;
    a                 ### => [_,1,2]
    b                 ### => [0,_,2]
    c                 ### => [0,1,_]
    a.inherit_mask(b,c);
    a                 ### => [_,_,_]

=== --- CArray#inherit_mask_replace(a1, a2, ...)
引数で与えられた配列 a1、a2、… のマスク状態の論理和をとり、
新しいマスク状態として設定する。
オブジェクト自身のマスク値は上記の論理和に含まれない点に注意する。

    a = CA_INT(0..2);
    b = CA_INT(0..2);
    c = CA_INT(0..2);
    a[0] = UNDEF;
    b[1] = UNDEF;
    c[2] = UNDEF;
    a                 ### => [_,1,2]
    b                 ### => [0,_,2]
    c                 ### => [0,1,_]
    a.inherit_mask_replace(b,c);
    a                 ### => [0,_,_]
