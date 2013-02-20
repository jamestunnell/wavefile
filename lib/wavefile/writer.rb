module WaveFile
  # Provides the ability to write data to a wave file.
  class Writer

    # Padding value written to the end of chunks whose payload is an odd number of bytes. The RIFF
    # specification requires that each chunk be aligned to an even number of bytes, even if the byte
    # count is an odd number.
    #
    # See http://www-mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/Docs/riffmci.pdf, page 11.
    EMPTY_BYTE = "\000"

    # The number of bytes at the beginning of a wave file before the sample data in the data chunk
    # starts, assuming this canonical format:
    #
    # RIFF Chunk Header (12 bytes)
    # Format Chunk (16 bytes for PCM, 18 bytes for floating point)
    # FACT Chunk (0 bytes for PCM, 12 bytes for floating point)
    # Data Chunk Header (8 bytes)
    #
    # All wave files written by Writer use this canonical format.
    CANONICAL_HEADER_BYTE_LENGTH = {:pcm => 36, :float => 50}

    MODE_WRITE = :modeWrite
    MODE_APPEND = :modeAppend
    MODES = [ MODE_WRITE, MODE_APPEND ]
    
    # Returns a constructed Writer object which is available for writing sample data to the specified
    # file (via the write method). When all sample data has been written, the Writer should be closed.
    # Note that the wave file being written to will NOT be valid (and playable in other programs) until
    # the Writer has been closed.
    #
    # If a block is given to this method, sample data can be written inside the given block. When the
    # block terminates, the Writer will be automatically closed (and no more sample data can be written).
    #
    # If no block is given, then sample data can be written until the close method is called.
    def initialize(file_name, format, mode = MODE_WRITE)
      @file_name = file_name
      @mode = mode
      
      case mode
      when MODE_WRITE
        @file = File.open(file_name, "wb")
        @format = format
        
        @sample_frames_existing = 0
  
        # Note that the correct sizes for the RIFF and data chunks can't be determined
        # until all samples have been written, so this header as written will be incorrect.
        # When close is called, the correct sizes will be re-written.
        write_header(0)
      when MODE_APPEND
        raise "file #{file_name} does not exist" unless File.exists?(file_name)
        info = Reader.info(@file_name)
        
        @file = File.open(@file_name, "ab+")
        @format = Format.new(info.channels, info.bits_per_sample, info.sample_rate)
        
        @sample_frames_existing = info.sample_frame_count
      else
        raise ArgumentError, "mode #{mode} is not supported"
      end
      
      @pack_code = PACK_CODES[@format.sample_format][@format.bits_per_sample]
      @sample_frames_written = 0

      if block_given?
        begin
          yield(self)
        ensure
          close
        end
      end
    end


    # Appends the sample data in the given Buffer to the end of the wave file.
    #
    # Returns the number of sample that have been written to the file so far.
    # Raises IOError if the Writer has been closed.
    def write(buffer)
      samples = buffer.convert(@format).samples
      @file.syswrite(samples.flatten.pack(@pack_code))
      @sample_frames_written += samples.length
    end


    # Returns true if the Writer is closed, and false if it is open and available for writing.
    def closed?
      @file.closed?
    end


    # Closes the Writer. After a Writer is closed, no more sample data can be written to it.
    #
    # Note that the wave file will NOT be valid until this method is called. The wave file
    # format requires certain information about the amount of sample data, and this can't be
    # determined until all samples have been written.
    #
    # Returns nothing.
    # Raises IOError if the Writer is already closed.
    def close
      # The RIFF specification requires that each chunk be aligned to an even number of bytes,
      # even if the byte count is an odd number. Therefore if an odd number of bytes has been
      # written, write an empty padding byte.
      #
      # See http://www-mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/Docs/riffmci.pdf, page 11.
      bytes_written = total_sample_frames * @format.block_align
      if bytes_written.odd?
        @file.syswrite(EMPTY_BYTE)
      end
      
      # In append mode, all output operations write data at the end of the file, so re-open
      # the file in write mode so the header can be updated before closing.
      if @mode == MODE_APPEND
        @file.close
        @file = File.open(@file_name, "wb")
      end
      
      # We can't know what chunk sizes to write for the RIFF and data chunks until all
      # samples have been written, so go back to the beginning of the file and re-write
      # those chunk headers with the correct sizes.
      @file.sysseek(0)
      write_header(total_sample_frames)

      @file.close
    end

    def duration_written
      Duration.new(@sample_frames_written, @format.sample_rate)
    end
    
    def duration_total
      Duration.new(total_sample_frames, @format.sample_rate)
    end

    # Returns the name of the Wave file that is being written to
    attr_reader :file_name

    # Returns a Format object describing the Wave file being written (number of channels, sample
    # format and bits per sample, sample rate, etc.)
    attr_reader :format

    # Returns the number of samples (per channel) that have been written to the file so far (since opening).
    # For example, if 1000 "left" samples and 1000 "right" samples have been written to a stereo file
    # since it was opened, this will return 1000.
    attr_reader :sample_frames_written

    # Returns the number of samples (per channel) contained in the file in total, including existing
    # samples (before file was opened) and those that were written after opening.
    # For example, if 1000 L/R samples exisited in a stereo file before it was opened, and 1000 L/R
    # samples have been written since it was opened, this will return 2000.
    def total_sample_frames
      @sample_frames_existing + @sample_frames_written
    end
    
  private
    # Writes the RIFF chunk header, format chunk, and the header for the data chunk. After this
    # method is called the file will be "queued up" and ready for writing actual sample data.
    def write_header(sample_frame_count)
      sample_data_byte_count = sample_frame_count * @format.block_align

      # Write the header for the RIFF chunk
      header = CHUNK_IDS[:riff]
      header += [CANONICAL_HEADER_BYTE_LENGTH[@format.sample_format] + sample_data_byte_count].pack(UNSIGNED_INT_32)
      header += WAVEFILE_FORMAT_CODE

      # Write the format chunk
      header += CHUNK_IDS[:format]
      header += [FORMAT_CHUNK_BYTE_LENGTH[@format.sample_format]].pack(UNSIGNED_INT_32)
      header += [FORMAT_CODES[@format.sample_format]].pack(UNSIGNED_INT_16)
      header += [@format.channels].pack(UNSIGNED_INT_16)
      header += [@format.sample_rate].pack(UNSIGNED_INT_32)
      header += [@format.byte_rate].pack(UNSIGNED_INT_32)
      header += [@format.block_align].pack(UNSIGNED_INT_16)
      header += [@format.bits_per_sample].pack(UNSIGNED_INT_16)
      if @format.sample_format == :float
        header += [0].pack(UNSIGNED_INT_16)
      end

      # Write the FACT chunk, if necessary
      unless @format.sample_format == :pcm
        header += CHUNK_IDS[:fact]
        header += [4].pack(UNSIGNED_INT_32)
        header += [sample_frame_count].pack(UNSIGNED_INT_32)
      end

      # Write the header for the data chunk
      header += CHUNK_IDS[:data]
      header += [sample_data_byte_count].pack(UNSIGNED_INT_32)

      @file.sysseek(0)
      @file.syswrite(header)
    end
  end
end
