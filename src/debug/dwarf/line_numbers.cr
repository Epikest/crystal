module Debug
  # DWARF reader.
  #
  # Documentation:
  # - <http://dwarfstd.org>
  module DWARF
    # Standard Line Number opcodes.
    # :nodoc:
    enum LNS : UInt8
      Copy             =  1
      AdvancePc        =  2
      AdvanceLine      =  3
      SetFile          =  4
      SetColumn        =  5
      NegateStmt       =  6
      SetBasicBlock    =  7
      ConstAddPc       =  8
      FixedAdvancePc   =  9
      SetPrologueEnd   = 10
      SetEpiloqueBegin = 11
      SetIsa           = 12
    end

    # Extended Line Number opcodes.
    # :nodoc:
    enum LNE : UInt8
      EndSequence      = 1
      SetAddress       = 2
      DefineFile       = 3
      SetDiscriminator = 4
    end

    # DWARF Line Numbers parser. Supports DWARF versions 2, 3 and 4.
    #
    # Usually located in the `.debug_line` section of ELF executables, or the
    # `__debug_line` section of Mach-O files.
    #
    # Documentation:
    # - [DWARF2](http://dwarfstd.org/doc/dwarf-2.0.0.pdf) section 6.2
    # - [DWARF3](http://dwarfstd.org/doc/Dwarf3.pdf) section 6.2
    # - [DWARF4](http://dwarfstd.org/doc/DWARF4.pdf) section 6.2
    struct LineNumbers
      # The state machine registers used to decompress the line number
      # sequences.
      #
      # :nodoc:
      struct Register
        # The Program Counter (PC) value corresponding to a machine instruction
        # generated by the compiler.
        property address : UInt64

        # The index of an operation inside a Very Long Instruction Word (VLIW)
        # instruction. Together with `address` they reference an individual
        # operation.
        property op_index : UInt32

        # Source file for the instruction.
        property file : UInt32

        # Line number within the source file. Starting at 1; the value 0 means
        # that the instruction can't be attributed to any source line.
        property line : UInt32

        # Column number within the source file. Starting at 1; the value 0 means
        # that a statement begins at the "left edge" of the line.
        property column : UInt32

        # Recommended breakpoint location.
        property is_stmt : Bool

        # Indicates that the instruction is the beginning of a basic block.
        property basic_block : Bool

        # Terminates a sequence of lines. Other information in the same row (of
        # the decoded matrix) isn't meaningful.
        property end_sequence : Bool

        # Indicates the instruction is one where execution should be
        # suspended (for an entry breakpoint).
        property prologue_end : Bool

        # Indicates the instruction is one where execution should be
        # suspended (for an exit breakpoint).
        property epilogue_begin : Bool

        # Applicable Instruction Set Architecture for the instruction.
        property isa : UInt32

        # Identifies the block to which the instruction belongs.
        property discriminator : UInt32

        def initialize(@is_stmt)
          @address = 0_u64
          @op_index = 0_u32
          @file = 1_u32
          @line = 1_u32
          @column = 0_u32
          @basic_block = false
          @end_sequence = false
          @prologue_end = false
          @epilogue_begin = false
          @isa = 0_u32
          @discriminator = 0_u32
        end

        def reset
          @basic_block = false
          @prologue_end = false
          @epilogue_begin = false
          @discriminator = 0_u32
        end
      end

      # The decoded line number information for an instruction.
      record Row,
        address : UInt64,
        op_index : UInt32,
        directory : Int32,
        file : Int32,
        line : Int32,
        column : Int32,
        end_sequence : Bool

      # An individual compressed sequence.
      #
      # :nodoc:
      struct Sequence
        property! offset : LibC::OffT
        property! unit_length : UInt32
        property! version : UInt16
        property! header_length : UInt32 # FIXME: UInt64 for DWARF64 (uncommon)
        property! minimum_instruction_length : UInt8
        property maximum_operations_per_instruction : UInt8
        property! default_is_stmt : Bool
        property! line_base : Int8
        property! line_range : UInt8
        property! opcode_base : UInt8

        # An array of how many args an array. Starts at 1 because 0 means an
        # extended opcode.
        getter standard_opcode_lengths

        # An array of directory names. Starts at 1; 0 means that the information
        # is missing.
        getter include_directories

        # An array of file names. Starts at 1; 0 means that the information is
        # missing.
        getter file_names

        def initialize
          @maximum_operations_per_instruction = 1_u8
          @include_directories = [""]
          @file_names = [{"", 0, 0, 0}]
          @standard_opcode_lengths = [0_u8]
        end

        # Returns the unit length, adding the size of the `unit_length`.
        def total_length
          unit_length + sizeof(typeof(unit_length))
        end
      end

      # Matrix of decompressed `Row` to search line number informations from the
      # address of an instruction.
      #
      # The matrix contains indexed references to `directories` and `files` to
      # reduce the memory usage of repeating a String many times.
      getter matrix : Array(Array(Row))

      # The array of indexed directory paths.
      getter directories : Array(String)

      # The array of indexed file names.
      getter files : Array(String)

      @offset : LibC::OffT

      def initialize(@io : IO::FileDescriptor, size)
        @offset = @io.tell
        @matrix = Array(Array(Row)).new
        @directories = [] of String
        @files = [] of String
        decode_sequences(size)
      end

      # Returns the `Row` for the given Program Counter (PC) address if found.
      def find(address)
        matrix.each do |rows|
          if row = rows.first?
            next if address < row.address
          end

          if row = rows.last?
            next if address > row.address
          end

          rows.each_with_index do |current_row, index|
            if current_row.address == address
              return current_row
            end

            if address < current_row.address
              if previous_row = rows[index - 1]?
                return previous_row
              end
            end
          end
        end

        nil
      end

      # Decodes the compressed matrix of addresses to line numbers.
      private def decode_sequences(size)
        # Map names to indexes to avoid doing linear scans over @files and @directories
        indexes = {
          directory: {} of String => Int32,
          filename:  {} of String => Int32,
        }

        while (@io.tell - @offset) < size
          sequence = Sequence.new

          sequence.offset = @io.tell - @offset
          sequence.unit_length = @io.read_bytes(UInt32)
          sequence.version = @io.read_bytes(UInt16)
          sequence.header_length = @io.read_bytes(UInt32)
          sequence.minimum_instruction_length = @io.read_byte.not_nil!

          if sequence.version >= 4
            sequence.maximum_operations_per_instruction = @io.read_byte.not_nil!
          end

          sequence.default_is_stmt = @io.read_byte.not_nil! == 1
          sequence.line_base = @io.read_bytes(Int8)
          sequence.line_range = @io.read_byte.not_nil!
          sequence.opcode_base = @io.read_byte.not_nil!

          read_opcodes(sequence)
          read_directory_table(sequence)
          read_filename_table(sequence)

          if @io.tell - @offset < sequence.offset + sequence.total_length
            read_statement_program(sequence, indexes)
          end
        end
      end

      private def read_opcodes(sequence)
        1.upto(sequence.opcode_base - 1) do
          sequence.standard_opcode_lengths << @io.read_byte.not_nil!
        end
      end

      private def read_directory_table(sequence)
        loop do
          name = @io.gets('\0').to_s.chomp('\0')
          break if name.empty?
          sequence.include_directories << name
        end
      end

      private def read_filename_table(sequence)
        loop do
          name = @io.gets('\0').to_s.chomp('\0')
          break if name.empty?
          dir = DWARF.read_unsigned_leb128(@io)
          time = DWARF.read_unsigned_leb128(@io)
          length = DWARF.read_unsigned_leb128(@io)
          sequence.file_names << {name, dir.to_i, time.to_i, length.to_i}
        end
      end

      private macro increment_address_and_op_index(operation_advance)
        if sequence.maximum_operations_per_instruction == 1
          registers.address += {{operation_advance}} * sequence.minimum_instruction_length
        else
          registers.address += sequence.minimum_instruction_length *
            ((registers.op_index + operation_advance) / sequence.maximum_operations_per_instruction)
          registers.op_index = (registers.op_index + operation_advance) % sequence.maximum_operations_per_instruction
        end
      end

      # TODO: support LNE::DefineFile (manually register file, uncommon)
      private def read_statement_program(sequence, indexes)
        registers = Register.new(sequence.default_is_stmt)

        loop do
          opcode = @io.read_byte.not_nil!

          if opcode >= sequence.opcode_base
            # special opcode
            adjusted_opcode = opcode - sequence.opcode_base
            operation_advance = adjusted_opcode / sequence.line_range
            increment_address_and_op_index(operation_advance)
            registers.line &+= sequence.line_base + (adjusted_opcode % sequence.line_range)
            register_to_matrix(sequence, registers, indexes)
            registers.reset
          elsif opcode == 0
            # extended opcode
            len = DWARF.read_unsigned_leb128(@io) - 1 # -1 accounts for the opcode
            extended_opcode = LNE.new(@io.read_byte.not_nil!)

            case extended_opcode
            when LNE::EndSequence
              registers.end_sequence = true
              register_to_matrix(sequence, registers, indexes)
              if (@io.tell - @offset - sequence.offset) < sequence.total_length
                registers = Register.new(sequence.default_is_stmt)
              else
                break
              end
            when LNE::SetAddress
              case len
              when 8 then registers.address = @io.read_bytes(UInt64)
              when 4 then registers.address = @io.read_bytes(UInt32).to_u64
              else        @io.skip(len)
              end
              registers.op_index = 0_u32
            when LNE::SetDiscriminator
              registers.discriminator = DWARF.read_unsigned_leb128(@io)
            else
              # skip unsupported opcode
              @io.read_fully(Bytes.new(len))
            end
          else
            # standard opcode
            standard_opcode = LNS.new(opcode)

            case standard_opcode
            when LNS::Copy
              register_to_matrix(sequence, registers, indexes)
              registers.reset
            when LNS::AdvancePc
              operation_advance = DWARF.read_unsigned_leb128(@io)
              increment_address_and_op_index(operation_advance)
            when LNS::AdvanceLine
              registers.line &+= DWARF.read_signed_leb128(@io)
            when LNS::SetFile
              registers.file = DWARF.read_unsigned_leb128(@io)
            when LNS::SetColumn
              registers.column = DWARF.read_unsigned_leb128(@io)
            when LNS::NegateStmt
              registers.is_stmt = !registers.is_stmt
            when LNS::SetBasicBlock
              registers.basic_block = true
            when LNS::ConstAddPc
              adjusted_opcode = 255 - sequence.opcode_base
              operation_advance = adjusted_opcode / sequence.line_range
              increment_address_and_op_index(operation_advance)
            when LNS::FixedAdvancePc
              registers.address += @io.read_bytes(UInt16).not_nil!
              registers.op_index = 0_u32
            when LNS::SetPrologueEnd
              registers.prologue_end = true
            when LNS::SetEpiloqueBegin
              registers.epilogue_begin = true
            when LNS::SetIsa
              registers.isa = DWARF.read_unsigned_leb128(@io)
            else
              # consume unknown opcode args
              n_args = sequence.standard_opcode_lengths[opcode.to_i]
              n_args.times { DWARF.read_unsigned_leb128(@io) }
            end
          end
        end
      end

      @current_sequence_matrix : Array(Row)?

      private def register_to_matrix(sequence, registers, indexes)
        file = sequence.file_names[registers.file]
        path = sequence.include_directories[file[1]]

        row = Row.new(
          registers.address,
          registers.op_index,
          register_directory(path, indexes[:directory]),
          register_filename(file[0], indexes[:filename]),
          registers.line.to_i,
          registers.column.to_i,
          registers.end_sequence
        )

        if rows = @current_sequence_matrix
          rows << row
        else
          matrix << (rows = [row])
          @current_sequence_matrix = rows
        end

        if registers.end_sequence
          @current_sequence_matrix = nil
        end
      end

      # When decoding statement programs when asking for the current
      # filename it's usually the case that it's the same as the old
      # one (because all info from a single file comes first, then
      # another file comes next, etc.). So we remember the last
      # mapped index to avoid unnecessary lookups.
      @last_filename : String?
      @last_filename_index = 0

      private def register_filename(name, filename_indexes)
        if name.same?(@last_filename)
          return @last_filename_index
        end

        @last_filename = name

        index = filename_indexes[name]? || @files.index(name)

        unless index
          index = @files.size
          @files << name
          filename_indexes[name] = index
        end

        @last_filename_index = index

        index
      end

      # Same logic as `@last_filename` but for directories
      @last_directory : String?
      @last_directory_index = 0

      private def register_directory(name, directory_indexes)
        if name.same?(@last_directory)
          return @last_directory_index
        end

        @last_directory = name

        index = directory_indexes[name]? || @directories.index(name)

        unless index
          index = @directories.size
          @directories << name
          directory_indexes[name] = index
        end

        @last_directory_index = index

        index
      end
    end
  end
end
