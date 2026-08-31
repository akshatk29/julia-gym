function palindrome(s)
    clean = lowercase(filter(isletter, s))
    return clean == reverse(clean)
end
