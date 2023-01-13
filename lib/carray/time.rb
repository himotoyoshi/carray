# ----------------------------------------------------------------------------
#
#  carray/time.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require "date"

class CArray
    
  def str_to_datetime (template = nil)
    if template
      return convert() {|v| DateTime.strptime(v, template) }
    else
      return convert() {|v| DateTime.parse(v) }
    end
  end

  def str_to_time (template = nil)
    if template
      return str_strptime(template)
    else
      return convert() {|v| Time.parse(v) }
    end
  end

  def time_format (template = nil)
    if template
      return time_strftime(template)
    else
      return convert(&:to_s)
    end    
  end

  def time_year
    return convert(:int, &:year)
  end

  def time_month
    return convert(:int, &:month)
  end

  def time_day
    return convert(:int, &:day)
  end

  def time_hour 
    return convert(:int, &:hour)
  end

  def time_minute
    return convert(:int, &:minute)
  end

  def time_second
    return convert(:double) {|d| d.second + d.second_fraction }
  end

  def time_jd
    return convert(:int, &:jd)
  end

  def time_ajd
    return convert(:double, &:ajd)
  end

  def time_is_leap
    return test(&:leap?)
  end

end

