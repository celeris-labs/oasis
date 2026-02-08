from dataclasses import dataclass
from coyote_test import fpga_test_case, fpga_stream, fpga_register
from random import randint

_N_STREAMS = 4

@dataclass
class _Read:
    vaddr: int
    size: int

@dataclass
class _Decoder:
    compression: int
    page_type: int
    num_values: int
    type: int

# For simplicity, we use Compression=None, Encoding=PLAIN so that data is
# directly passed through.
class RDMAParquetTestCase(fpga_test_case.FPGATestCase):
    alternative_vfpga_top_file = "rdma_parquet_test.sv"
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
    def _set_in_out(self, streams: dict[int, list[tuple[_Read, _Decoder]]]) -> None:
        self.remote_rdma_write(0, fpga_stream.Stream(self.data_type, self.data))

        def pos_to_register(pos: int) -> bytearray:
            return bytearray(pos.to_bytes(8, 'little'))

        def byte_to_register(pos: int) -> bytearray:
            return bytearray(pos.to_bytes(1, 'little'))

        for stream, ops in streams.items():

            for (read_cfg, decoder_cfg) in ops:
                read_offst = 4

                self.write_register(fpga_register.vFPGARegister(read_offst + stream*2 + 0, pos_to_register(read_cfg.vaddr)))
                self.write_register(fpga_register.vFPGARegister(read_offst + stream*2 + 1, pos_to_register(read_cfg.size)))

                decoder_offst = read_offst + _N_STREAMS * 2

                self.write_register(fpga_register.vFPGARegister(decoder_offst + stream*4 + 0, byte_to_register(decoder_cfg.compression)))
                self.write_register(fpga_register.vFPGARegister(decoder_offst + stream*4 + 1, byte_to_register(decoder_cfg.page_type)))
                self.write_register(fpga_register.vFPGARegister(decoder_offst + stream*4 + 2, byte_to_register(decoder_cfg.num_values)))
                self.write_register(fpga_register.vFPGARegister(decoder_offst + stream*4 + 3, byte_to_register(decoder_cfg.type)))


                pos = read_cfg.vaddr // self.data_width
                n = read_cfg.size // self.data_width
                bytes = self.data[pos:pos+n]
                self.set_expected_output(stream, fpga_stream.Stream(self.data_type, bytes))
        

    def test_one_stream_one_request(self):
        # Arrange
        self._set_in_out({
            0: [(_Read(0, self.len//4), _Decoder(0, 2, 0, 1))]
        })

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_one_stream_two_requests(self):
        # Arrange
        self._set_in_out({
            0: [
                (_Read(0, self.len//4), _Decoder(0, 2, 0, 1)),
                (_Read(self.len//4, self.len//4), _Decoder(0, 2, 0, 1))
            ]
        })

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_multiple_streams(self):
        # Arrange
        self._set_in_out({
            0: [
                (_Read(0, self.len//4), _Decoder(0, 2, 0, 1))
            ],
            1: [
                (_Read(0, self.len//4), _Decoder(0, 2, 0, 1))
            ]
        })

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
