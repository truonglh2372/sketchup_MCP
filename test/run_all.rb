# Runs every *_test.rb in one process.
Dir[File.join(__dir__, "*_test.rb")].sort.each { |f| require f }
