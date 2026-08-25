/* ---------------------------------------------------------------------------

  CArray pool framework primitives.  Collapses the per-class
  `dim` / `strides` / per-view-tail metadata allocations into a
  single `_pool` buffer, owned by the CArray struct and freed in
  one xfree.  Reduces the number of xmalloc / xfree pairs per
  CArray lifecycle and keeps the metadata cache-adjacent.

  Primary motivation: CABlock and CAWindow view creation.  Those
  two carry the most per-instance metadata (dim + strides + per-
  axis tail), so consolidating their allocations into one pool
  buffer roughly doubles clone throughput.  Other view types and
  entities adopted the same primitives for uniform alloc/free
  discipline; the perf gain on those is modest.

  Internal C API (no Ruby surface, no Init function).  Three
  entry points:

    ca_array_alloc       struct + pool in one allocation; used by
                         the C `*_new` constructors that build a
                         CArray from C without a Ruby wrapper.
    ca_array_pool_alloc  pool only; used by `*_initialize_copy`
                         where TypedData_Make_Struct has already
                         allocated the C struct.
    ca_array_free        frees both struct and pool; dispatched
                         from per-class free callbacks.

  Per obj_type, two function-pointer hooks are registered into
  `ca_func[obj_type]`: `pool_bytes(ndim)` computes the pool size,
  and `pool_init(ca, ndim)` wires the struct's `dim` / `strides` /
  tail pointers into the freshly allocated pool.  See the per-view
  Init_* setup for examples.

  Mixed dispatch: an obj_type that has not yet registered the pool
  hooks falls through to its legacy per-field ALLOC_N path
  (`ca->_pool == NULL`); existing CArrays from such classes continue
  to free correctly because `ca_array_free` is a no-op when
  `_pool` is NULL.  This kept the migration incremental and
  remains safe in mixed object-graph scenarios.

  See devel/PROPOSAL_CARRAY_POOL_STANDARDIZATION.md for the design.

---------------------------------------------------------------------------- */

#include "carray.h"
#include <string.h>

/* Allocate struct + pool in one shot, then run pool_init.
 *
 * Called by per-class C `*_new` constructors. */
void *
ca_array_alloc (int8_t obj_type, int8_t ndim)
{
  ca_operation_function_t *func = &ca_func[obj_type];
  CArray *ca = xmalloc(func->struct_size);
  memset(ca, 0, func->struct_size);
  ca_array_pool_alloc(ca, obj_type, ndim);
  return ca;
}

/* Allocate just the _pool buffer and run pool_init.  The C struct
 * itself is assumed already allocated (e.g. by TypedData_Make_Struct
 * via `*_s_allocate`).
 *
 * Called by per-class `*_initialize_copy` and by ca_array_alloc above. */
void
ca_array_pool_alloc (void *ap, int8_t obj_type, int8_t ndim)
{
  CArray *ca = (CArray *) ap;
  ca_operation_function_t *func = &ca_func[obj_type];
  ca->ndim  = ndim;
  ca->_pool = xmalloc(func->pool_bytes(ndim));
  func->pool_init(ca, ndim);
}

/* Free struct + pool in one shot.  Safe when `ca->_pool == NULL`
 * (the pool xfree is skipped, the struct xfree always runs); this
 * lets the per-class free callback dispatch here uniformly whether
 * or not its obj_type has migrated to pool registration.
 *
 * Called by per-class free_* callbacks (= `func->free_object`). */
void
ca_array_free (void *ap)
{
  CArray *ca = (CArray *) ap;
  if (ca->_pool) {
    xfree(ca->_pool);
    ca->_pool = NULL;
  }
  xfree(ca);
}
