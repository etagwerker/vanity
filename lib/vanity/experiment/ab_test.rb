module Vanity
  module Experiment

    # Experiment alternative.  See AbTest#alternatives.
    class Alternative

      def initialize(experiment, id, value, participants, converted, conversions) #:nodoc:
        @experiment = experiment
        @id = id
        @name = "option #{(@id + 65).chr}"
        @value = value
        @participants, @converted, @conversions = participants, converted, conversions
      end

      # Alternative id, only unique for this experiment.
      attr_reader :id
     
      # Alternative name (option A, option B, etc).
      attr_reader :name

      # Alternative value.
      attr_reader :value

      # Experiment this alternative belongs to.
      attr_reader :experiment

      # Number of participants who viewed this alternative.
      attr_reader :participants

      # Number of participants who converted on this alternative.
      attr_reader :converted

      # Number of conversions for this alternative (same participant may be counted more than once).
      attr_reader :conversions

      # Conversion rate calculated as converted/participants.
      def conversion_rate
        c, p = converted.to_f, participants.to_f
        p > 0 ? c/p : 0.0
      end

      def <=>(other)
        conversion_rate <=> other.conversion_rate 
      end

      def ==(other)
        id == other.id && experiment == other.experiment
      end

      def to_s #:nodoc:
        name
      end

      def inspect #:nodoc:
        "#{name}: #{value} #{converted}/#{participants}"
      end

    end


    # The meat.
    class AbTest < Base
      class << self

        def confidence(score) #:nodoc:
          score = score.abs
          confidence = AbTest::Z_TO_CONFIDENCE.find { |z,p| score >= z }
          confidence ? confidence.last : 0
        end

        def friendly_name
          "A/B Test" 
        end

      end

      def initialize(*args) #:nodoc:
        super
        @alternatives = [false, true]
      end

      # -- Alternatives --

      # Call this method once to specify values for the A/B test.  At least two
      # values are required.
      #
      # Call without argument to previously defined alternatives (see Alternative).
      #
      # For example:
      #   experiment "Background color" do
      #     alternatives "red", "blue", "orange"
      #   end
      #
      #   alts = experiment(:background_color).alternatives
      #   puts "#{alts.count} alternatives, with the colors: #{alts.map(&:value).join(", ")}"
      def alternatives(*args)
        unless args.empty?
          @alternatives = args.clone
        end
        class << self
          alias :alternatives :_alternatives
        end
        alternatives
      end

      def _alternatives #:nodoc:
        alts = []
        @alternatives.each_with_index do |value, i|
          participants = redis.scard(key("alts:#{i}:participants")).to_i
          converted = redis.scard(key("alts:#{i}:converted")).to_i
          conversions = redis[key("alts:#{i}:conversions")].to_i
          alts << Alternative.new(self, i, value, participants, converted, conversions)
        end
        alts
      end

      # Returns an Alternative with the specified value.
      def alternative(value)
        alternatives.find { |alt| alt.value == value }
      end

      # Sets this test to two alternatives: false and true.
      def false_true
        alternatives false, true
      end
      alias true_false false_true

      # Chooses a value for this experiment.
      #
      # This method returns different values for different identity (see
      # #identify), and consistenly the same value for the same
      # expriment/identity pair.
      #
      # For example:
      #   color = experiment(:which_blue).choose
      def choose
        if active?
          identity = identify
          index = alternative_for(identity)
          redis.sadd key("alts:#{index}:participants"), identity
          check_completion!
          @alternatives[index]
        elsif alternative = outcome
          alternative.value
        else
          @alternatives.first
        end
      end

      # Records a conversion.
      #
      # For example:
      #   experiment(:which_blue).conversion!
      def conversion!
        if active?
          identity = identify
          index = alternative_for(identity)
          if redis.sismember(key("alts:#{index}:participants"), identity)
            redis.sadd key("alts:#{index}:converted"), identity
            redis.incr key("alts:#{index}:conversions")
          end
          check_completion!
        end
      end

      
      # -- Testing --
     
      # Forces this experiment to use a particular alternative. Useful for
      # tests, e.g.
      #
      #   setup do
      #     experiment(:green_button).select(true)
      #   end
      #
      #   def test_shows_green_button
      #     . . .
      #   end
      #
      # Use nil to clear out selection:
      #   teardown do
      #     experiment(:green_button).select(nil)
      #   end
      def chooses(value)
        index = @alternatives.index(value)
        raise ArgumentError, "No alternative #{value.inspect} for #{name}" unless index
        Vanity.context.session[:vanity] ||= {}
        Vanity.context.session[:vanity][id] = index
        self
      end


      # -- Reporting --

      # Returns an object with the following attributes:
      # [:alts]  List of alternatives as structures (see below).
      # [:best]  Best alternative.
      # [:base]  Second best alternative.
      # [:least] Least performing (but more than zero) alternative.
      # [:choice]  Choice alterntive, either selected outcome or best alternative (with confidence).
      #
      # Each alternative is an object with the following attributes:
      # [:id]    Identifier.
      # [:name]  Alternative name.
      # [:value] Alternative value.
      # [:conv]  Conversion rate (0.0 to 1.0, rounded to 3 places).
      # [:pop]   Population size (participants).
      # [:diff]  Difference from least performant altenative (percentage).
      # [:z]     Z-score compared to base (above).
      # [:conf]  Confidence based on z-score (0, 90, 95, 99, 99.9).
      def score
        struct = Struct.new(:id, :name, :value, :conv, :pop, :diff, :z, :conf)
        alts = alternatives.map { |alt| struct.new(alt.id, alt.name, alt.value, alt.conversion_rate.round(3), alt.participants) }
        # sort by conversion rate to find second best and 2nd best
        sorted = alts.sort_by(&:conv)
        base = sorted[-2]
        # calculate z-score
        pc = base.conv
        nc = base.pop
        alts.each do |alt|
          p = alt.conv
          n = alt.pop
          alt.z = (p - pc) / ((p * (1-p)/n) + (pc * (1-pc)/nc)).abs ** 0.5
          alt.conf = AbTest.confidence(alt.z)
        end
        # difference is measured from least performant
        if least = sorted.find { |alt| alt.conv > 0 }
          alts.each do |alt|
            alt.diff = (alt.conv - least.conv) / least.conv * 100 if alt.conv > least.conv
          end
        end
        # best alternative is one with highest conversion rate (best shot).
        # choice alternative can only pick best if we have high confidence (>90%).
        best = sorted.last if sorted.last.conv > 0
        choice = outcome ? alts[outcome.id] : (best && best.conf >= 90 ? best : nil)
        Struct.new(:alts, :best, :base, :least, :choice).new(alts, best, base, least, choice)
      end

      # Use the score returned by #score to derive a conclusion.  Returns an
      # array of claims.
      def conclusion(score = score)
        claims = []
        # only interested in sorted alternatives with conversion
        sorted = score.alts.select { |alt| alt.conv > 0.0 }.sort_by(&:conv).reverse
        if sorted.size > 1
          # start with alternatives that have conversion, from best to worst,
          # then alternatives with no conversion.
          sorted |= score.alts
          # we want a result that's clearly better than 2nd best.
          best, second = sorted[0], sorted[1]
          if best.conv > second.conv
            diff = ((best.conv - second.conv) / second.conv * 100).round
            better = " (%d%% better than %s)" % [diff, second.name] if diff > 0
            claims << "The best choice is %s: it converted at %.1f%%%s." % [best.name, best.conv * 100, better]
            if best.conf >= 90
              claims << "With %d%% probability this result is statistically significant." % score.best.conf
            else
              claims << "This result is not statistically significant, suggest you continue this experiment."
            end
            sorted.delete best
          end
          sorted.each do |alt|
            if alt.conv > 0.0
              claims << "%s converted at %.1f%%." % [alt.name.gsub(/^o/, "O"), alt.conv * 100]
            else
              claims << "%s did not convert." % alt.name.gsub(/^o/, "O")
            end
          end
        else
          claims << "This experiment did not run long enough to find a clear winner."
        end
        claims << "#{score.choice.name.gsub(/^o/, "O")} selected as the best alternative." if score.choice
        claims
      end


      # -- Completion --

      # Defines how the experiment can choose the optimal outcome on completion.
      #
      # The default implementation looks for the best (highest conversion rate)
      # alternative.  If it's certain (95% or more) that this alternative is
      # better than the first alternative, it switches to that one.  If it has
      # no such certainty, it starts using the first alternative exclusively.
      #
      # The default implementation reads like this:
      #   outcome_is do
      #     highest = alternatives.sort.last
      #     highest.confidence >= 95 ? highest ? alternatives.first
      #   end
      def outcome_is(&block)
        raise ArgumentError, "Missing block" unless block
        raise "outcome_is already called on this experiment" if @outcome_is
        @outcome_is = block
      end

      # Alternative chosen when this experiment was completed.
      def outcome
        outcome = redis[key("outcome")]
        outcome && alternatives[outcome.to_i]
      end

      def complete!
        return unless active?
        super
        if @outcome_is
          begin
            result = @outcome_is.call
            outcome = result.id if result && result.experiment == self
          rescue
            # TODO: logging
          end
        else
          best = score.best
          outcome = best.id if best
        end
        # TODO: logging
        redis.setnx key("outcome"), outcome
      end

      
      # -- Store/validate --

      def save
        fail "Experiment #{name} needs at least two alternatives" unless alternatives.count >= 2
        super
      end

      def reset!
        @alternatives.count.times do |i|
          redis.del key("alts:#{i}:participants")
          redis.del key("alts:#{i}:converted")
          redis.del key("alts:#{i}:conversions")
        end
        redis.del key(:outcome)
        super
      end

      def destroy
        reset
        super
      end

    private

      # Chooses an alternative for the identity and returns its index. This
      # method always returns the same alternative for a given experiment and
      # identity, and randomly distributed alternatives for each identity (in the
      # same experiment).
      def alternative_for(identity)
        session = Vanity.context.session[:vanity]
        index = session && session[id]
        index ||= Digest::MD5.hexdigest("#{name}/#{identity}").to_i(17) % @alternatives.count
      end

      begin
        a = 0
        # Returns array of [z-score, percentage]
        norm_dist = (-5.0..3.1).step(0.01).map { |x| [x, a += 1 / Math.sqrt(2 * Math::PI) * Math::E ** (-x ** 2 / 2)] }
        # We're really only interested in 90%, 95%, 99% and 99.9%.
        Z_TO_CONFIDENCE = [90, 95, 99, 99.9].map { |pct| [norm_dist.find { |x,a| a >= pct }.first, pct] }.reverse
      end

    end
  end
end
