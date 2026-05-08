from dataclasses import dataclass
from random import randint
from coyote_test import fpga_stream, fpga_register
from libstf_utils.output_writer_test_case import OutputWriterTestCase

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

class IntegrationTestCase(OutputWriterTestCase):
    """This integration test case is used to do light verification of the Oasis vfpga_top.svh. The 
    decoder itself has it's own test suite in the ParCore repo.

    For simplicity, we use Compression=None, Encoding=PLAIN so that data is directly passed through.
    """

    debug_mode = True

    def __init__(self, a) -> None:
        n = 4096
        self.data = [randint(-n, n) for _ in range(n)]
        self.data_type = fpga_stream.StreamType.SIGNED_INT_32
        self.data_width = fpga_stream.get_bytes_for_stream_type(self.data_type)
        self.len = n
        self.streams = None

        super().__init__(a)

    # Method that gets executed once per test case
    def setUp(self):
        return super().setUp()

    def simulate_fpga(self):
        def pos_to_register(pos: int) -> bytearray:
            return bytearray(pos.to_bytes(8, 'little'))

        def byte_to_register(pos: int) -> bytearray:
            return bytearray(pos.to_bytes(1, 'little'))
        
        assert self.streams is not None and len(self.streams) > 0, "Cannot perform integration test without stream"
    
        self.remote_rdma_write(0, fpga_stream.Stream(self.data_type, self.data))

        self.simulate_fpga_non_blocking()

        read_offset      = self.global_config.get_config_bounds(0x2f966a70f04c0e93)[0]
        chunk_dec_offset = self.global_config.get_config_bounds(0x5c19f934407065bd)[0]
        page_dec_offset  = self.global_config.get_config_bounds(0xc0779792c320630e)[0]
        for stream, ops in self.streams.items():
            for (read_cfg, decoder_cfg) in ops:
                self.write_register(fpga_register.vFPGARegister(read_offset + stream * 2 + 0, pos_to_register(read_cfg.vaddr)))
                self.write_register(fpga_register.vFPGARegister(read_offset + stream * 2 + 1, pos_to_register(read_cfg.size)))

                self.write_register(fpga_register.vFPGARegister(chunk_dec_offset + stream * 4 + 0, byte_to_register(decoder_cfg.compression)))
                self.write_register(fpga_register.vFPGARegister(chunk_dec_offset + stream * 4 + 1, pos_to_register(decoder_cfg.num_values)))
                self.write_register(fpga_register.vFPGARegister(chunk_dec_offset + stream * 4 + 2, pos_to_register(decoder_cfg.num_values)))
                self.write_register(fpga_register.vFPGARegister(chunk_dec_offset + stream * 4 + 3, byte_to_register(decoder_cfg.type)))

                self.write_register(fpga_register.vFPGARegister(page_dec_offset + stream * 3 + 0, byte_to_register(decoder_cfg.page_type)))
                self.write_register(fpga_register.vFPGARegister(page_dec_offset + stream * 3 + 1, pos_to_register(decoder_cfg.num_values)))
                self.write_register(fpga_register.vFPGARegister(page_dec_offset + stream * 3 + 2, byte_to_register(0)))

                pos = read_cfg.vaddr // self.data_width
                n = read_cfg.size // self.data_width
                bytes = self.data[pos:pos+n]
                self.set_expected_output(stream, fpga_stream.Stream(self.data_type, bytes))

        self.finish_fpga_simulation()

    def test_one_stream_one_request(self):
        self.streams = {
            0: [(_Read(0, self.len//4), _Decoder(0, 2, 0, 1))]
        }

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_one_stream_two_requests(self):
        self.streams = {
            0: [
                (_Read(0, self.len//4), _Decoder(0, 2, 0, 1)),
                (_Read(self.len//4, self.len//4), _Decoder(0, 2, 0, 1))
            ]
        }

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_multiple_streams(self):
        self.streams = {
            0: [
                (_Read(0, self.len//4), _Decoder(0, 2, 0, 1))
            ],
            1: [
                (_Read(0, self.len//4), _Decoder(0, 2, 0, 1))
            ]
        }

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
