module RbsInfer
  # Módulo com helpers compartilhados para parsing de anotações RBS
  # (rbs-inline e @rbs) em comentários próximos a definições.
  # Usado por ClassMemberCollector e CallerFileAnalyzer.
  module RbsAnnotationParser
    def lines_between_are_blank_or_comments(lines, from_line, to_line)
      ((from_line)...(to_line - 1)).all? do |i|
        line = lines[i]
        next true if line.nil?
        stripped = line.strip
        stripped.empty? || stripped.start_with?("#")
      end
    end
  end
end
