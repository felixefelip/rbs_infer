class ParseXml
	def initialize(xml)
		@xml = xml
	end

	def parse
    { order: @xml.at_css("order") }
	end
end
