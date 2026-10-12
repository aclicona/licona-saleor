"""B-1249: cada manager del lote debe conservar SU requestor (late binding de `lambda: user`)."""

from types import SimpleNamespace

from ..dataloaders import PluginManagerByRequestorDataloader


def test_batch_load_binds_each_manager_to_its_own_requestor():
    # given: un lote con dos requestors distintos (no hace falta BD: el getter es perezoso)
    requestor_a = object()
    requestor_b = object()
    loader = PluginManagerByRequestorDataloader(SimpleNamespace(allow_replica=True))

    # when
    managers = loader.batch_load([requestor_a, requestor_b])

    # then: sin el fix todos devolvian el ultimo requestor del bucle
    assert managers[0].requestor_getter() is requestor_a
    assert managers[1].requestor_getter() is requestor_b
