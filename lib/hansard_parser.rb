require 'speech'
require 'mechanize_proxy'
require 'configuration'
require 'debates'
require 'builder_alpha_attributes'
require 'house'

class UnknownSpeaker
  def initialize(name)
    @name = name
  end
  
  def id
    "unknown"
  end
  
  def name
    Name.title_first_last(@name)
  end
end

require 'rubygems'
require 'log4r'

class HansardParser
  attr_reader :logger
  
  def initialize(people)
    @people = people
    conf = Configuration.new
    
    # Set up logging
    @logger = Log4r::Logger.new 'HansardParser'
    # Log to both standard out and the file set in configuration.yml
    @logger.add(Log4r::Outputter.stdout)
    @logger.add(Log4r::FileOutputter.new('foo', :filename => conf.log_path, :trunc => false,
      :formatter => Log4r::PatternFormatter.new(:pattern => "[%l] %d :: %M")))
  end
  
  def parse_date(date, xml_reps_filename, xml_senate_filename)
    #parse_date_house(date, xml_reps_filename, House.representatives)
    parse_date_house(date, xml_senate_filename, House.senate)
  end
  
  def parse_date_house(date, xml_filename, house)
    @logger.info "Parsing #{house} speeches for #{date.strftime('%a %d %b %Y')}..."
    url = "http://parlinfoweb.aph.gov.au/piweb/browse.aspx?path=Chamber%20%3E%20#{house.representatives? ? "House" : "Senate"}%20Hansard%20%3E%20#{date.year}%20%3E%20#{date.day}%20#{Date::MONTHNAMES[date.month]}%20#{date.year}"

    debates = Debates.new(date, house)
    
    # Required to workaround long viewstates generated by .NET (whatever that means)
    # See http://code.whytheluckystiff.net/hpricot/ticket/13
    Hpricot.buffer_size = 400000

    agent = MechanizeProxy.new
    agent.cache_subdirectory = date.to_s

    begin
      page = agent.get(url)
      # HACK: Don't know why if the page isn't found a return code isn't returned. So, hacking around this.
      if page.title == "ParlInfo Web - Error"
        throw "ParlInfo Web - Error"
      end
    rescue
      logger.warn "Could not retrieve overview page for date #{date}"
      return
    end
    # Structure of the page is such that we are only interested in some of the links
    page.links[30..-4].each do |link|
      parse_sub_day_page(link.to_s, agent.click(link), debates, date, house)
      # This ensures that every sub day page has a different major count which limits the impact
      # of when we start supporting things like written questions, procedurial text, etc..
      debates.increment_major_count
    end
    
    debates.output(xml_filename)
  end
  
  def parse_sub_day_page(link_text, sub_page, debates, date, house)
    # Only going to consider speeches for the time being
    if link_text =~ /^Speech:/ || link_text =~ /^QUESTIONS WITHOUT NOTICE:/ || link_text =~ /^QUESTIONS TO THE SPEAKER:/
      # Link text for speech has format:
      # HEADING > NAME > HOUR:MINS:SECS
      split = link_text.split('>').map{|a| a.strip}
      logger.error "Expected split to have length 3 in link text: #{link_text}" unless split.size == 3
      time = split[2]
      parse_sub_day_speech_page(sub_page, time, debates, date, house)
    #elsif link_text =~ /^Procedural text:/
    #  # Assuming no time recorded for Procedural text
    #  parse_sub_day_speech_page(sub_page, nil, debates, date)
    elsif link_text == "Official Hansard" || link_text =~ /^Start of Business/ || link_text == "Adjournment"
      # Do nothing - skip this entirely
    elsif link_text =~ /^Procedural text:/ || link_text =~ /^QUESTIONS IN WRITING:/ || link_text =~ /^Division:/ ||
        link_text =~ /^REQUEST FOR DETAILED INFORMATION:/ ||
        link_text =~ /^Petition:/ || link_text =~ /^PRIVILEGE:/ || link_text == "Interruption" ||
        link_text =~ /^QUESTIONS ON NOTICE:/
      logger.info "Not yet supporting: #{link_text}"
    else
      throw "Unsupported: #{link_text}"
    end
  end

  def parse_sub_day_speech_page(sub_page, time, debates, date, house)
    top_content_tag = sub_page.search('div#contentstart').first
    throw "Page on date #{date} at time #{time} has no content" if top_content_tag.nil?
    
    # Extract permanent URL of this subpage. Also, quoting because there is a bug
    # in XML Builder that for some reason is not quoting attributes properly
    url = quote(sub_page.links.text("[Permalink]").uri.to_s)

    newtitle = sub_page.search('div#contentstart div.hansardtitle').map { |m| m.inner_html }.join('; ')
    newsubtitle = sub_page.search('div#contentstart div.hansardsubtitle').map { |m| m.inner_html }.join('; ')
    # Replace any unicode characters
    newtitle = replace_unicode(newtitle)
    newsubtitle = replace_unicode(newsubtitle)

    debates.add_heading(newtitle, newsubtitle, url)

    speaker = nil
    top_content_tag.children.each do |e|
      class_value = e.attributes["class"]
      if e.name == "div"
        if class_value == "hansardtitlegroup" || class_value == "hansardsubtitlegroup"
        elsif class_value == "speech0" || class_value == "speech1"
          e.children[1..-1].each do |e|
            speaker = parse_speech_block(e, speaker, time, url, debates, date, house)
            debates.increment_minor_count
          end
        elsif class_value == "motionnospeech" || class_value == "subspeech0" || class_value == "subspeech1" ||
            class_value == "motion" || class_value = "quote"
          speaker = parse_speech_block(e, speaker, time, url, debates, date, house)
          debates.increment_minor_count
        else
          throw "Unexpected class value #{class_value} for tag #{e.name}"
        end
      elsif e.name == "p"
        speaker = parse_speech_block(e, speaker, time, url, debates, date, house)
        debates.increment_minor_count
      elsif e.name == "table"
        if class_value == "division"
          debates.increment_minor_count
          # Ignore (for the time being)
        else
          throw "Unexpected class value #{class_value} for tag #{e.name}"
        end
      else
        throw "Unexpected tag #{e.name}"
      end
    end
  end
  
  # Returns new speaker
  def parse_speech_block(e, speaker, time, url, debates, date, house)
    speakername, interjection = extract_speakername(e)
    # Only change speaker if a speaker name was found
    this_speaker = speakername ? lookup_speaker(speakername, date, house) : speaker
    debates.add_speech(this_speaker, time, url, clean_speech_content(url, e))
    # With interjections the next speech should never be by the person doing the interjection
    if interjection
      speaker
    else
      this_speaker
    end
  end
  
  def extract_speakername(content)
    interjection = false
    # Try to extract speaker name from talkername tag
    tag = content.search('span.talkername a').first
    tag2 = content.search('span.speechname').first
    if tag
      name = tag.inner_html
      # Now check if there is something like <span class="talkername"><a>Some Text</a></span> <b>(Some Text)</b>
      tag = content.search('span.talkername ~ b').first
      # Only use it if it is surrounded by brackets
      if tag && tag.inner_html.match(/\((.*)\)/)
        name += " " + $~[0]
      end
    elsif tag2
      name = tag2.inner_html
    # If that fails try an interjection
    elsif content.search("div.speechType").inner_html == "Interjection"
      interjection = true
      text = strip_tags(content.search("div.speechType + *").first)
      m = text.match(/([a-z].*) interjecting/i)
      if m
        name = m[1]
      else
        m = text.match(/([a-z].*)—/i)
        if m
          name = m[1]
        else
          name = nil
        end
      end
    # As a last resort try searching for interjection text
    else
      m = strip_tags(content).match(/([a-z].*) interjecting/i)
      if m
        name = m[1]
        interjection = true
      else
        m = strip_tags(content).match(/^([a-z].*)—/i)
        name = m[1] if m and generic_speaker?(m[1])
      end
    end
    [name, interjection]
  end
  
  # Replace unicode characters by their equivalent
  def replace_unicode(text)
    t = text.gsub("\342\200\230", "'")
    t.gsub!("\342\200\231", "'")
    t.gsub!("\342\200\224", "-")
    t.each_byte do |c|
      if c > 127
        logger.warn "Found invalid characters in: #{t.dump}"
      end
    end
    t
  end
  
  def clean_speech_content(base_url, content)
    doc = Hpricot(content.to_s)
    doc.search('div.speechType').remove
    doc.search('span.talkername ~ b').remove
    doc.search('span.talkername').remove
    doc.search('span.talkerelectorate').remove
    doc.search('span.talkerrole').remove
    doc.search('hr').remove
    make_motions_and_quotes_italic(doc)
    remove_subspeech_tags(doc)
    fix_links(base_url, doc)
    make_amendments_italic(doc)
    fix_attributes_of_p_tags(doc)
    fix_attributes_of_td_tags(doc)
    fix_motionnospeech_tags(doc)
    # Do pure string manipulations from here
    text = doc.to_s
    text = text.gsub("(\342\200\224)", '')
    text = text.gsub(/([^\w])\342\200\224/) {|m| m[0..0]}
    text = text.gsub(/\(\d{1,2}.\d\d a.m.\)/, '')
    text = text.gsub(/\(\d{1,2}.\d\d p.m.\)/, '')
    text = text.gsub('()', '')
    text = text.gsub('<div class="separator"></div>', '')
    # Look for tags in the text and display warnings if any of them aren't being handled yet
    text.scan(/<[a-z][^>]*>/i) do |t|
      m = t.match(/<([a-z]*) [^>]*>/i)
      if m
        tag = m[1]
      else
        tag = t[1..-2]
      end
      allowed_tags = ["b", "i", "dl", "dt", "dd", "ul", "li", "a", "table", "td", "tr", "img"]
      if !allowed_tags.include?(tag) && t != "<p>" && t != '<p class="italic">'
        throw "Tag #{t} is present in speech contents: " + text
      end
    end
    doc = Hpricot(text)
    #p doc.to_s
    doc
  end
  
  def fix_motionnospeech_tags(content)
    content.search('div.motionnospeech').wrap('<p></p>')
    replace_with_inner_html(content, 'div.motionnospeech')
    content.search('span.speechname').remove
    content.search('span.speechelectorate').remove
    content.search('span.speechrole').remove
    content.search('span.speechtime').remove
  end
  
  def fix_attributes_of_p_tags(content)
    content.search('p.parabold').wrap('<b></b>')
    content.search('p').each do |e|
      class_value = e.get_attribute('class')
      if class_value == "block" || class_value == "parablock" || class_value == "parasmalltablejustified" ||
          class_value == "parasmalltableleft" || class_value == "parabold" || class_value == "paraheading"
        e.remove_attribute('class')
      elsif class_value == "paraitalic"
        e.set_attribute('class', 'italic')
      elsif class_value == "italic" && e.get_attribute('style')
        e.remove_attribute('style')
      end
    end
  end
  
  def fix_attributes_of_td_tags(content)
    content.search('td').each do |e|
      e.remove_attribute('style')
    end
  end
  
  def fix_links(base_url, content)
    content.search('a').each do |e|
      href_value = e.get_attribute('href')
      if href_value.nil?
        # Remove a tags
        e.swap(e.inner_html)
      else
        e.set_attribute('href', URI.join(base_url, href_value))
      end
    end
    content.search('img').each do |e|
      e.set_attribute('src', URI.join(base_url, e.get_attribute('src')))
    end
    content
  end
  
  def replace_with_inner_html(content, search)
    content.search(search).each do |e|
      e.swap(e.inner_html)
    end
  end
  
  def make_motions_and_quotes_italic(content)
    content.search('div.motion p').set(:class => 'italic')
    replace_with_inner_html(content, 'div.motion')
    content.search('div.quote p').set(:class => 'italic')
    replace_with_inner_html(content, 'div.quote')
    content
  end
  
  def make_amendments_italic(content)
    content.search('div.amendments div.amendment0 p').set(:class => 'italic')
    content.search('div.amendments div.amendment1 p').set(:class => 'italic')
    replace_with_inner_html(content, 'div.amendment0')
    replace_with_inner_html(content, 'div.amendment1')
    replace_with_inner_html(content, 'div.amendments')
    content
  end
  
  def remove_subspeech_tags(content)
    replace_with_inner_html(content, 'div.subspeech0')
    replace_with_inner_html(content, 'div.subspeech1')
    content
  end
  
  def quote(text)
    text.sub('&', '&amp;')
  end

  def lookup_speaker(speakername, date, house)
    throw "speakername can not be nil in lookup_speaker" if speakername.nil?

    # Handle speakers where they are referred to by position rather than name
    if house.representatives?
      if speakername =~ /^the speaker/i
        member = @people.house_speaker(date)
      elsif speakername =~ /^the deputy speaker \((.*)\)/i
        speakername = $~[1]
      elsif speakername =~ /^the deputy speaker/i
        member = @people.deputy_house_speaker(date)
      end
    else
      if speakername =~ /^the president/i
        member = @people.senate_president(date)
      elsif speakername =~ /^the acting deputy president \((.*)\)/i || speakername =~ /^the temporary chairman \((.*)\)/i
        speakername = $~[1]
      elsif speakername =~ /^(the )?chairman/i || speakername =~ /^the deputy president/i
        # The "Chairman" in the main Senate Hansard is when the Senate is sitting as a committee of the whole Senate.
        # In this case, the "Chairman" is the deputy president. See http://www.aph.gov.au/senate/pubs/briefs/brief06.htm#3
        member = @people.deputy_senate_president(date)
      end
    end
    
    # If member hasn't already been set then lookup using speakername
    if member.nil?
      name = Name.title_first_last(speakername)
      member = @people.find_member_by_name_current_on_date(name, date, house)
      if member.nil?
        logger.warn "Unknown speaker #{speakername}" unless generic_speaker?(speakername)
        member = UnknownSpeaker.new(speakername)
      end
    end
    
    member
  end
  
  def generic_speaker?(speakername)
    return speakername =~ /^(a )?(honourable|opposition|government) members?$/i
  end

  def strip_tags(doc)
    str=doc.to_s
    str.gsub(/<\/?[^>]*>/, "")
  end

  def min(a, b)
    if a < b
      a
    else
      b
    end
  end
end
