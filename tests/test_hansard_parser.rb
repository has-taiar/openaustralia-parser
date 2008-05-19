$:.unshift "#{File.dirname(__FILE__)}/../lib"

require 'test/unit'
require 'hansard_parser'
require 'rubygems'
require 'hpricot'

class TestHansardParser < Test::Unit::TestCase
  def setup
    @parser = HansardParser.new(nil)
  end
  
  def test_make_motions_and_quotes_italic
    doc = Hpricot('<p>I move:</p><div class="motion"><p>Some text</p></div>')
    @parser.make_motions_and_quotes_italic(doc)
    assert_equal('<p>I move:</p><p class="italic">Some text</p>', doc.to_s)
  end
  
  def test_remove_subspeech_tags
    doc = Hpricot('<div class="subspeech0"><p>Some Text</p></div><div class="subspeech0"><p>Some Other Text</p></div>')
    @parser.remove_subspeech_tags(doc)
    assert_equal('<p>Some Text</p><p>Some Other Text</p>', doc.to_s)
  end

  def test_fix_links_relative_link
    doc = Hpricot('<p>The <a href="foo.html">Link Text</a> Some Text</p>')
    @parser.fix_links("http://website/bar/blah.html", doc)
    assert_equal('<p>The <a href="http://website/bar/foo.html">Link Text</a> Some Text</p>', doc.to_s)
  end
  
  def test_fix_links_absolute_link
    doc = Hpricot('<p>The <a href="http://anothersite/foo.html">Link Text</a> Some Text</p>')
    @parser.fix_links("http://website/bar/blah.html", doc)
    assert_equal('<p>The <a href="http://anothersite/foo.html">Link Text</a> Some Text</p>', doc.to_s)
  end
  
  def test_fix_links_empty_a_tag
    doc = Hpricot('<p>The <a>Link Text</a> Some Text</p>')
    @parser.fix_links("http://website/bar/blah.html", doc)
    assert_equal('<p>The Link Text Some Text</p>', doc.to_s)
  end
  
  def test_make_amendments_italic
    doc = Hpricot('<div class="amendments"><div class="amendment0"><p class="paraParlAmend">Some Text</p></div><div class="amendment1"><p class="paraParlAmend">Some more text</p></div></div>')
    @parser.make_amendments_italic(doc)
    assert_equal('<p class="italic">Some Text</p><p class="italic">Some more text</p>', doc.to_s)
  end
  
  def test_fix_attributes_of_p_tags_block
    doc = Hpricot('<p class="block">Some Text</p>')
    @parser.fix_attributes_of_p_tags(doc)
    assert_equal('<p>Some Text</p>', doc.to_s)
  end
  
  def test_fix_attributes_of_p_tags_parablock
    doc = Hpricot('<p class="parablock">Some Text</p>')
    @parser.fix_attributes_of_p_tags(doc)
    assert_equal('<p>Some Text</p>', doc.to_s)
  end

  def test_fix_attributes_of_p_tags_paraitalic
    doc = Hpricot('<p class="paraitalic">Some Text</p>')
    @parser.fix_attributes_of_p_tags(doc)
    assert_equal('<p class="italic">Some Text</p>', doc.to_s)
  end
  
  def test_fix_attributes_of_p_tags_parasmalltablejustified
    doc = Hpricot('<p class="parasmalltablejustified">Some Text</p>')
    @parser.fix_attributes_of_p_tags(doc)
    assert_equal('<p>Some Text</p>', doc.to_s)
  end
  
  def test_fix_attributes_of_p_tags_text_indent
    doc = Hpricot('<p class="italic" style="text-indent: 0;">Some Text</p>')
    @parser.fix_attributes_of_p_tags(doc)
    assert_equal('<p class="italic">Some Text</p>', doc.to_s)
  end
  
  def test_fix_attributes_of_p_tags_parasmalltableleft
    doc = Hpricot('<p class="parasmalltableleft">Some Text</p>')
    @parser.fix_attributes_of_p_tags(doc)
    assert_equal('<p>Some Text</p>', doc.to_s)
  end
  
  def test_fix_attributes_of_td_tags_style
    doc = Hpricot('<td style="foo">Some Text</td>')
    @parser.fix_attributes_of_td_tags(doc)
    assert_equal('<td>Some Text</td>', doc.to_s)
  end
  
  def test_fix_attributes_of_p_tags_parabold
    doc = Hpricot('<p class="parabold">Some Text</p>')
    @parser.fix_attributes_of_p_tags(doc)
    assert_equal('<b><p>Some Text</p></b>', doc.to_s)
  end
  
  def test_extract_speakername_from_talkername_tag_normal_form
    doc = Hpricot('<p><span class="talkername"><a HREF="blah">Mr Hunt</a></span></p>')
    assert_equal('Mr Hunt', @parser.extract_speakername_from_talkername_tag(doc))
  end

  def test_extract_speakername_from_talkername_tag_no_tag
    doc = Hpricot('<p>Mr Hunt</p>')
    assert(@parser.extract_speakername_from_talkername_tag(doc).nil?)
  end
  
  def test_extract_speakername_from_talkername_tag_bad_markup_form
    doc = Hpricot('<p><span class="talkername"><a>The Deputy Speaker</a></span><b>(Mr Hunt)</p>')
    assert_equal('The Deputy Speaker (Mr Hunt)', @parser.extract_speakername_from_talkername_tag(doc))
  end
end