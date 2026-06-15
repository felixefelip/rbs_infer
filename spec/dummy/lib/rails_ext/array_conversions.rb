# Reopens a generic core class (`Array`) via `Receiver.include`
# (felixefelip/rbs_infer#38). Regression guard: the emitted `class Array`
# reopening must carry Array's exact type parameters (`[unchecked out Elem]`),
# or RBS raises GenericParameterMismatchError and poisons the whole Steep
# environment.
module ChoiceSentenceArrayConversion
  def to_choice_sentence
    to_sentence two_words_connector: " or ", last_word_connector: ", or "
  end
end

Array.include ChoiceSentenceArrayConversion
