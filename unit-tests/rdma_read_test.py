from coyote_test import fpga_test_case, fpga_stream
from random import randint
import struct

class RDMATestCase(fpga_test_case.FPGATestCase):
    alternative_vfpga_top_file = "rdma_read_test.sv"
    debug_mode = True
    # verbose_logging = True

    def __init__(self, a) -> None:
        n = 4096
        self.data = [randint(-n, n) for _ in range(n)]
        self.data_type = fpga_stream.StreamType.SIGNED_INT_32
        self.data_width = fpga_stream.get_bytes_for_stream_type(self.data_type)
        self.len = n

        super().__init__(a)

    # Method that gets executed once per test case
    def setUp(self):
        return super().setUp()
    
    # Overwrite of the parent classes simulation method.
    # Can be used to implement common behavior between tests
    def simulate_fpga(self):
        return super().simulate_fpga()

    # buffers are a list of (len, vaddr)
    def _set_in_out(self, buffers: list[tuple[int, int]]) -> None:
        self.remote_rdma_write(0, fpga_stream.Stream(self.data_type, self.data))
        inputs = [[int(x) * self.data_width for x in xs] for xs in buffers]
        output = [self.data[vaddr:vaddr+len] for len, vaddr in buffers]

        for input in inputs:
            self.set_stream_input(0, fpga_stream.Stream(fpga_stream.StreamType.UNSIGNED_INT_64, input))
        for out in output:
            self.set_expected_output(0, fpga_stream.Stream(self.data_type, out))
        

    def test_one_rdma_read_identity(self):
        # Arrange
        self._set_in_out([(self.len, 0)])

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_two_rdma_read_identity(self):
        # Arrange
        self._set_in_out([(self.len, 0), (self.len, 0)])

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_many_rdma_read(self):
        # Arrange
        self._set_in_out([
            (64, self.len - 64),
            (128, self.len - 128),
            (self.len, 0),
            (self.len, 0)
        ])

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_odd_rdma_reads(self):
        # Arrange
        self._set_in_out([
            (13, self.len // 2),
            (35, 78),
            (0, 1025)
        ])

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
