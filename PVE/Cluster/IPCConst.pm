package PVE::Cluster::IPCConst;
use strict; use warnings;

use base 'Exporter';

my %IPC_OPS;
BEGIN {
  %IPC_OPS = (
    CFS_IPC_GET_FS_VERSION => 1,
    CFS_IPC_GET_CLUSTER_INFO => 2,
    CFS_IPC_GET_GUEST_LIST => 3,
    CFS_IPC_SET_STATUS => 4,
    CFS_IPC_GET_STATUS => 5,
    CFS_IPC_GET_CONFIG => 6,
    CFS_IPC_LOG_CLUSTER_MSG => 7,
    CFS_IPC_GET_CLUSTER_LOG => 8,
    CFS_IPC_GET_RRD_DUMP => 10,
    CFS_IPC_GET_GUEST_CONFIG_PROPERTY => 11,
    CFS_IPC_VERIFY_TOKEN => 12,
    CFS_IPC_GET_GUEST_CONFIG_PROPERTIES => 13,
  );
}
use constant \%IPC_OPS;
our @EXPORT = keys(%IPC_OPS);
